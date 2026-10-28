#!/bin/sh
# a stand-in for k4-claude act: an answer streamed as k4 lines, in Markdown
case "$1" in
  ask|follow) printf 'k4:sid 3f13d34d\nk4:meta 09:44\nk4:delta Two units in `~/.config/systemd/user/`.\\n\\n## The timer\\n\\n```ini\\n[Timer]\\nOnCalendar=*-*-* 02:00\\n```\\n\\n1. Reload: `systemctl --user daemon-reload`\\n2. Enable it\nk4:limit five_hour 0.66 1793105400\n' ;;
  limited) ;;
  *) echo "ran $*" ;;
esac
