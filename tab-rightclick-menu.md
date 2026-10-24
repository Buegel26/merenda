# Add mouse rightclick menu to editor etabs

# Context
There is a popup menu missing for the etabs of the kosmo editor giving options.

# Glossar
- <xxx>: press of key, e.g. <tab> press of tab key
- pane: the ui pane where the etabs are managed
- etab: an ui tab element holding on moe instance (editor tab), the short version etab is not to be used in commits
- editor: the embedded moe editor in one etab

# Issues
## 1. No popup menu when using right mouse on an etab with tab options
- currently an etab can be selected or closed using the mouse which is correct as is
- besides just using the close option of an etab element it should be possible to use rightclick of the mouse on the etab to get a popup menu with different options:
	- Close: close the etab
	- Close others: to close all other tabs
	- Two duplicate options that act like split but duplicate the current etab state (editor + file open)
		- Duplicate right: to duplicate the current etab to the right
		- Duplicate below: to duplicate the current etab on the bottom

# Rules
- language to use is nim
- always test that fixes do not break previous tests of the merenda library and its sublibraries.
- to run the tests you may have to set the locale to "C" for running the tests, the users system is running in a mixed configuration leading to test issues
- ensure that navigation outside the pane is intact
- ensure that very application specific fixes stay in kosmo, not in the generic merenda with nimkit etc.
- fix one issue at a time, the ask the human to check if the fix works
- do not commit without the ok of the human
- all single fixes go into the branch "kosmo-tab-rightclick-menu"
- do not push to origin