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
