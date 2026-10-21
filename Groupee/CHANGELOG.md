# Changelog

All notable changes to Groupee are documented here.

## [0.3.0] - 2026-10-21

### Added
- XP per hour in party member tooltips, averaged over the last 10 minutes, with an estimate of the time left to level.
- Version check: Groupee says in chat when a group member has a newer version, or one that can't share XP with yours, and the party frame bar shows "old version" or "newer version" for them.
- `/groupee version` lists your version and your party members' versions.

### Fixed
- Party members showed "no addon" when the client reported their name as "Name Realm" instead of "Name-Realm", so their XP was never matched to them.

## [0.2.0] - 2026-10-17

### Added
- Addon compartment entry in the minimap dropdown: left-click shows or hides Groupee, right-click switches between bars on the party frames and the separate window, and hovering shows a tooltip with both.
- Icon and Social category in the addon list.

### Changed
- Now targets WoW Forever and Retail (Interface 16001, 120100, 120105) instead of Classic Era.
