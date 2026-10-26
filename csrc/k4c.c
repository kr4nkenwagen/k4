// C side of k4: stb implementations plus a small, layout-free API so the Odin
// code never mirrors stb struct layouts.
#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"
#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#define STBI_ONLY_JPEG
#define STBI_ONLY_BMP
#define STBI_ONLY_GIF
#include "stb_image.h"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"
#include <stdlib.h>

void *k4_font_new(const unsigned char *data, int index) {
	int off = stbtt_GetFontOffsetForIndex(data, index);
	if (off < 0) return NULL;
	stbtt_fontinfo *f = malloc(sizeof *f);
	if (!f || !stbtt_InitFont(f, data, off)) { free(f); return NULL; }
	return f;
}
float k4_font_scale_em(void *f, float px) { return stbtt_ScaleForMappingEmToPixels(f, px); }
void k4_font_vmetrics(void *f, int *asc, int *desc, int *gap) { stbtt_GetFontVMetrics(f, asc, desc, gap); }
int k4_font_glyph_index(void *f, int cp) { return stbtt_FindGlyphIndex(f, cp); }
void k4_font_glyph_hmetrics(void *f, int g, int *adv, int *lsb) { stbtt_GetGlyphHMetrics(f, g, adv, lsb); }
unsigned char *k4_font_glyph_bitmap(void *f, float scale, float shift_x, int g, int *w, int *h, int *xoff, int *yoff) {
	return stbtt_GetGlyphBitmapSubpixel(f, scale, scale, shift_x, 0, g, w, h, xoff, yoff);
}
void k4_free(void *p) { free(p); }

unsigned char *k4_image_load(const char *path, int *w, int *h) {
	int n;
	return stbi_load(path, w, h, &n, 4);
}
int k4_png_write(const char *path, int w, int h, const void *rgba) {
	return stbi_write_png(path, w, h, 4, rgba, w * 4);
}

// ---------- colour bitmap fonts (CBDT/CBLC with PNG strikes: Noto Color Emoji) ----------
// stbtt_InitFont refuses fonts without outlines; set up what character lookup and
// horizontal metrics need, and read the glyph images ourselves.

static int k4_init_cmap(stbtt_fontinfo *info, unsigned char *data, int fontstart) {
	stbtt_uint32 cmap = stbtt__find_table(data, fontstart, "cmap");
	info->data = data;
	info->fontstart = fontstart;
	info->cff = stbtt__new_buf(NULL, 0);
	info->head = stbtt__find_table(data, fontstart, "head");
	info->hhea = stbtt__find_table(data, fontstart, "hhea");
	info->hmtx = stbtt__find_table(data, fontstart, "hmtx");
	info->loca = info->glyf = info->kern = info->gpos = 0;
	info->svg = -1;
	if (!cmap || !info->head || !info->hhea || !info->hmtx) return 0;
	stbtt_uint32 t = stbtt__find_table(data, fontstart, "maxp");
	info->numGlyphs = t ? ttUSHORT(data + t + 4) : 0xffff;
	int n = ttUSHORT(data + cmap + 2);
	info->index_map = 0;
	for (int i = 0; i < n; ++i) {
		stbtt_uint32 rec = cmap + 4 + 8 * i;
		int plat = ttUSHORT(data + rec), enc = ttUSHORT(data + rec + 2);
		if ((plat == STBTT_PLATFORM_ID_MICROSOFT && (enc == STBTT_MS_EID_UNICODE_BMP || enc == STBTT_MS_EID_UNICODE_FULL)) || plat == STBTT_PLATFORM_ID_UNICODE)
			info->index_map = cmap + ttULONG(data + rec + 4);
	}
	if (!info->index_map) return 0;
	info->indexToLocFormat = ttUSHORT(data + info->head + 50);
	return 1;
}

// A font with colour bitmaps and no outlines (NULL otherwise).
void *k4_font_new_color(const unsigned char *data, int index) {
	int off = stbtt_GetFontOffsetForIndex(data, index);
	if (off < 0) return NULL;
	if (!stbtt__find_table((unsigned char *)data, off, "CBDT") || !stbtt__find_table((unsigned char *)data, off, "CBLC")) return NULL;
	stbtt_fontinfo *f = calloc(1, sizeof *f);
	if (!f || !k4_init_cmap(f, (unsigned char *)data, off)) { free(f); return NULL; }
	return f;
}

// Glyph g's image (RGBA, straight alpha) from the first CBLC strike; *ppem is the strike's
// size, bearings and advance are in strike pixels (bearing y: baseline to the top).
unsigned char *k4_font_color_glyph(void *fi, int g, int *w, int *h, int *bx, int *by, int *adv, int *ppem) {
	stbtt_fontinfo *f = fi;
	unsigned char *d = f->data;
	stbtt_uint32 cblc = stbtt__find_table(d, f->fontstart, "CBLC"), cbdt = stbtt__find_table(d, f->fontstart, "CBDT");
	if (!cblc || !cbdt) return NULL;
	stbtt_uint32 nsizes = ttULONG(d + cblc + 4);
	for (stbtt_uint32 si = 0; si < nsizes; ++si) {
		unsigned char *bs = d + cblc + 8 + si * 48;
		stbtt_uint32 arr = cblc + ttULONG(bs), nsub = ttULONG(bs + 8);
		int start = ttUSHORT(bs + 40), end = ttUSHORT(bs + 42);
		if (g < start || g > end) continue;
		*ppem = bs[45];
		for (stbtt_uint32 k = 0; k < nsub; ++k) {
			unsigned char *e = d + arr + k * 8;
			int first = ttUSHORT(e), last = ttUSHORT(e + 2);
			if (g < first || g > last) continue;
			unsigned char *ist = d + arr + ttULONG(e + 4);
			int ifmt = ttUSHORT(ist), imgfmt = ttUSHORT(ist + 2);
			stbtt_uint32 base = cbdt + ttULONG(ist + 4), off = 0, len = 0;
			unsigned char *bigm = NULL;
			switch (ifmt) {
			case 1: off = ttULONG(ist + 8 + (g - first) * 4); len = ttULONG(ist + 8 + (g - first + 1) * 4) - off; break;
			case 3: off = ttUSHORT(ist + 8 + (g - first) * 2); len = ttUSHORT(ist + 8 + (g - first + 1) * 2) - off; break;
			case 2: len = ttULONG(ist + 8); bigm = ist + 12; off = len * (g - first); break;
			case 4: {
				stbtt_uint32 n = ttULONG(ist + 8);
				for (stbtt_uint32 j = 0; j < n; ++j) {
					unsigned char *p = ist + 12 + j * 4;
					if (ttUSHORT(p) == g) { off = ttUSHORT(p + 2); len = ttUSHORT(p + 6) - off; break; }
				}
				if (!len) return NULL;
			} break;
			case 5: {
				len = ttULONG(ist + 8); bigm = ist + 12;
				stbtt_uint32 n = ttULONG(ist + 20), j;
				for (j = 0; j < n && ttUSHORT(ist + 24 + j * 2) != g; ++j) {}
				if (j == n) return NULL;
				off = len * j;
			} break;
			default: return NULL;
			}
			unsigned char *img = d + base + off, *png;
			int plen, mh, mw, mbx, mby, madv;
			switch (imgfmt) {
			case 17: mh = img[0]; mw = img[1]; mbx = (signed char)img[2]; mby = (signed char)img[3]; madv = img[4]; plen = ttULONG(img + 5); png = img + 9; break;
			case 18: mh = img[0]; mw = img[1]; mbx = (signed char)img[2]; mby = (signed char)img[3]; madv = img[4]; plen = ttULONG(img + 8); png = img + 12; break;
			case 19:
				if (!bigm) return NULL;
				mh = bigm[0]; mw = bigm[1]; mbx = (signed char)bigm[2]; mby = (signed char)bigm[3]; madv = bigm[4]; plen = ttULONG(img); png = img + 4; break;
			default: return NULL;
			}
			(void)len; (void)mw; (void)mh;
			int n;
			unsigned char *rgba = stbi_load_from_memory(png, plen, w, h, &n, 4);
			if (!rgba) return NULL;
			*bx = mbx; *by = mby; *adv = madv;
			return rgba;
		}
	}
	return NULL;
}
