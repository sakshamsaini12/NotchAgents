# dmgbuild settings for make_dmg.sh: the app and an Applications shortcut on the drawn background,
# placed where the background's arrow expects them. Paths come in through `defines`.
import os

app = defines["app"]
format = "UDZO"
compression_level = 9
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
background = defines["background"]
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
window_rect = ((200, 120), (660, 420))
default_view = "icon-view"
arrange_by = None
icon_size = 128
text_size = 13
icon_locations = {os.path.basename(app): (170, 250), "Applications": (490, 250)}
