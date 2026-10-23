"""dmgbuild layout; called by release.sh with paths supplied as defines."""
import os

application = defines['app']
guide = defines['guide']
files = [application, (guide, 'Read Me.html')]
symlinks = {'Applications': '/Applications'}
format = 'UDZO'
filesystem = 'HFS+'
icon = os.path.join(application, 'Contents', 'Resources', 'LocalLink.icns')
background = defines['background']
window_rect = ((120, 120), (760, 440))
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = 'icon-view'
include_icon_view_settings = True
include_list_view_settings = False
arrange_by = None
icon_size = 104
text_size = 13
label_pos = 'bottom'
icon_locations = {'LocalLink.app': (216, 216), 'Applications': (546, 216), 'Read Me.html': (672, 368)}
hide_extensions = ['Read Me.html']
