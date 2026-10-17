# Groupee

Share your XP bar with your party members.

Groupee shows the XP progress of everyone in your party who also runs the addon, including their rested XP. It works on WoW Forever and Retail.

## Features

- **XP bars on the party frames.** A thin bar under each party member's mana bar shows their XP. On raid-style party frames it is a strip along the top edge.
- **Separate window.** If you prefer, the bars can sit in a small movable window instead, with each member's name in class color and their level.
- **Tooltips.** Hovering a party member shows their XP percentage and any rested XP.
- **Minimap button.** Groupee has an entry in the addon compartment dropdown on the minimap.

Party members without Groupee show as "no addon". Players at max level show "Max level".

## Installation

1. Download the latest release.
2. Copy the `Groupee` folder into your AddOns folder:
   - WoW Forever: `World of Warcraft\_forever_\Interface\AddOns`
   - Retail: `World of Warcraft\_retail_\Interface\AddOns`
3. Restart the game or type `/reload`.

## Usage

Join a party with someone else who runs Groupee. Their XP appears automatically and updates as they gain XP.

### Addon compartment

| Click | Action |
| --- | --- |
| Left-click | Show or hide Groupee |
| Right-click | Switch between bars on the party frames and the separate window |

### Slash commands

| Command | Action |
| --- | --- |
| `/groupee attach` | Show bars on the party frames (default) |
| `/groupee detach` | Show bars in a separate window |
| `/groupee lock` | Lock the window in place |
| `/groupee unlock` | Unlock the window so you can drag it |
| `/groupee reset` | Move the window back to its default position |
| `/groupee show` | Show Groupee |
| `/groupee hide` | Hide Groupee |
| `/groupee sync` | Ask the party to resend their XP |

## Notes

- Only party members are shown, up to four.
- XP is shared through hidden addon messages, so each player must have Groupee installed for their XP to show.
- On Retail, the game limits addon messages in some situations, such as inside instances, so updates may pause there.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

## License

MIT. See [LICENSE](LICENSE).
