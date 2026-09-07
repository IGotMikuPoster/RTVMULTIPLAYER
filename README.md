# kazmer's multiplayer RTV mod

## ✦ UPDATED FOR 0.4.18

**Improved revives, updated AI ragdoll synchronization, and smoother dropped items. Safe-zone saving and reloading passed isolated local testing.**

Multiplayer for Road to Vostok, for up to 8 players. Current version: **0.4.18**.

Packaged mod versions will be available in the [Releases tab](https://github.com/IGotMikuPoster/RTVMULTIPLAYER/releases). This repository contains source, not an install-ready mod package.

## Before playing

This is an experimental community mod and still needs actual gameplay testing. Testing has been limited to a few sessions with other players: I do not own a second copy, so only the most important features have received hands-on multiplayer testing. Automated checks are not a substitute for a full playthrough. Back up your saves and use disposable items when testing storage or furniture.

Everyone needs a legitimate copy of Road to Vostok, a compatible Metro Mod Loader, and the same multiplayer mod version. The installed game scripts were last checked on 6 September 2026 against the previously audited 0.1.1.3 scripts. Future game updates and other mods may affect compatibility.

When using Steam networking, actual Steam names are only available for players who own a genuine copy of Road to Vostok. Players who cannot be identified through Steam ownership will instead appear as "Vostok Survivor".

## Features

- Multiplayer menu with Steam hosting, invitations, and direct-address connections.
- Up to 8 players, visible held weapons, movement animations, shared footsteps and gunshots. Unarmed movement currently uses an idle upper-body pose; proper unarmed walking animations are planned.
- Host-controlled enemies, damage, shared loot, containers, doors, and world state.
- Updated client-side AI ragdoll synchronization and smoother dropped-item movement.
- Group travel voting and group sleep; living players must agree.
- Downed-player screen and teammate revives:
  - **Bandages:** restore 20 HP and retain injuries, with 15 seconds of protection from status health drain.
  - **Medkit, IFAK and AFAK:** restore 100 HP and clear medical debuffs. Survival meters below 20 rise to 20; carry-weight penalties remain.
  - Attacks, active fire and drowning still cause damage during the bandage grace period.
- Personal crafting and task rewards, with local character checkpoints tied to player identity and the host's run.
- Shared placed shelter furniture and storage, personal furniture catalogs, and one furniture editor at a time.
- Exclusive access to shared containers and traders while another player is using them.

These systems are implemented, but are not guaranteed bug-free or compatible with every other mod.

## Connecting

Install a packaged release in the game's mods folder and enable it in Metro Mod Loader. Launch the modded game and open Multiplayer.

## Steam networking

For Steam connections, use Host with Steam and Invite Friends. Players with a genuine copy of Road to Vostok can be identified by their actual Steam names and Steam ownership can be checked when connecting.

Players who cannot be identified as genuine owners will be displayed as "Vostok Survivor" rather than their Steam name.

## Direct / LAN networking

You can also play without using the Steam networking mode through a reachable direct address. This is the recommended option when Steam networking is unavailable or unsuitable. Tailscale or another compatible VPN/relay setup can provide a virtual LAN connection; players must configure it themselves.

Direct internet hosting may require UDP port 9058 forwarding, depending on the router and network. The mod does not provide its own relay service.

Direct/LAN networking is separate from Steam's ownership and friend-invite system. It can be used as an alternative connection method when Steam networking cannot be used, but the mod is intended for legitimate copies of Road to Vostok.

There will be no Spacewar fallback or Steam-emulation support. I do not condone piracy of the game. But using direct connection through tailscale is a perfect loophole if you do not own a genuine copy of the game. After all, this is a community mod. I wont restrict people from using it just for not buying the game. However it will be a bit harder to set up.

## Known issues and limitations

- Shared shelter storage, furniture placement and area changes passed local multiplayer testing with isolated profiles. Safe-zone save/reload retained player inventories and survival stats. Furniture packing with stored contents, interrupted transfers and separate-computer Steam/Tailscale persistence still need further testing.
- Disconnecting or crashing during furniture packing or placement can lose or duplicate items. Host world saves and client catalog saves are not a single atomic transaction.
- Character checkpoints are stored locally, not in a host-backed, cross-PC save service. **Keep backups on each player's computer.**
- Running two game instances on the same computer requires separate save folders. Otherwise, they can overwrite each other's saves.
- Updated ragdolls and dropped-item smoothing still need confirmation over real Steam/Tailscale connections, particularly with latency or packet loss.
- Player weapon grips, attachments, animations, enemy motion and shot audio need more testing across weapons and network conditions.
- Arbitrary third-person clothing and persistent bodies across disconnects/restarts are not complete features. Returning to a downed body after changing zones passed local testing, but disconnect/restart persistence is separate.
- Grenade flight/bounces and smoke presentation are not fully synchronized. Exact armor damage and reconnect recovery still need work.
- Loose objects on furniture must be removed before moving or packing it. Internal furniture storage is limited to 128 entries by the current protocol.
- Modified clients are not secure inventory proofs. Play with people you trust. Other mods that replace the same game interactions can conflict.

## Feedback

Please [open an issue](https://github.com/IGotMikuPoster/RTVMULTIPLAYER/issues) for problems during gameplay. Include the mod/game versions, whether you were hosting or joining, Steam or direct networking, other installed mods, and steps to reproduce it. Screenshots and relevant logs help; remove private addresses or other personal information before posting.

You can also contact me on Discord: **kazmerx**, or leave a comment on the ModWorkshop mod page.

## Source and license

The source includes the game-side scripts and Go Steam companion. Compiled executables, Steam API binaries, game assets, personal saves, and temporary build files are not included. Use a packaged release to play; the source alone is not install-ready.

Internal folder names and identifiers are retained for compatibility with existing saves and the mod loader. See [LICENSE](LICENSE) and [third-party notices](THIRD_PARTY_NOTICES.md). This is an unofficial mod, not endorsed by Road to Vostok Ltd. or Valve.
