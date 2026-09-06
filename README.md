# kazmer's multiplayer RTV mod

Multiplayer for Road to Vostok, for up to 8 players. Current version: **0.4.17**.

Packaged mod versions will be available in the [Releases tab](https://github.com/IGotMikuPoster/RTVMULTIPLAYER/releases). This repository contains source, not an install-ready mod package.

## Before playing

This is an experimental community mod and still needs actual gameplay testing. Testing has been limited to a few sessions with other players: I do not own a second copy, so only the most important features have received hands-on multiplayer testing. Automated checks are not a substitute for a full playthrough. Back up your saves and use disposable items when testing storage or furniture.

Everyone needs a legitimate copy of Road to Vostok, a compatible Metro Mod Loader, and the same multiplayer mod version. The installed game scripts were last checked on 6 September 2026 against the previously audited 0.1.1.3 scripts. Future game updates and other mods may affect compatibility.

## Features

- Multiplayer menu with Steam hosting, invitations, and direct-address connections.
- Up to 8 players, Steam names, remote player models, held equipment, and movement animation.
- Host-controlled enemies, damage, shared loot, containers, doors, and world state.
- Group travel voting and group sleep; living players must agree.
- Downed-player screen and teammate revives: bandages restore 20 HP; Medkit, IFAK, and AFAK restore 100 HP.
- Personal crafting and task rewards, with local character checkpoints tied to player identity and the host's run.
- Shared placed shelter furniture and storage, personal furniture catalogs, and one furniture editor at a time.
- Exclusive access to shared containers and traders while another player is using them.

These systems are implemented, but are not guaranteed bug-free or compatible with every other mod.

## Connecting

Install a packaged release in the game's `mods` folder and enable it in Metro Mod Loader. Launch the modded game and open **Multiplayer**. For Steam connections, use **Host with Steam** and **Invite Friends**. Steam mode checks ownership of Road to Vostok.

You can also play without using the Steam networking mode, through a reachable direct address. Tailscale or another compatible VPN/relay setup can provide that connection; players must configure it themselves. Direct internet hosting may require UDP port 9058 forwarding, depending on the router and network. The mod does not provide its own relay service.

There will be no Spacewar fallback or Steam-emulation support. I do not condone piracy of the game. Direct networking is an alternative connection method, not a replacement for owning the game.

## Known issues and limitations

- Shelter cabinet access and furniture packing/placement are recent changes. Contents surviving area changes, reconnects, and a host restart still need real multiplayer verification.
- Disconnecting or crashing during furniture packing or placement can lose or duplicate items. Host world saves and client catalog saves are not a single atomic transaction.
- Character checkpoints are stored locally. They are not a host-backed, cross-PC save service; keep backups on each player's computer.
- Player weapon grips, attachments, animations, enemy motion, and shot audio need more testing across weapons and network conditions. Arbitrary third-person clothing and persistent bodies across disconnects/restarts are not complete features.
- Grenade flight/bounces and smoke presentation are not fully synchronized. Exact armor damage and reconnect recovery still need work.
- Loose objects on furniture must be removed before moving or packing it. Internal furniture storage is limited to 128 entries by the current protocol.
- Modified clients are not secure inventory proofs. Play with people you trust. Other mods that replace the same game interactions can conflict.

## Feedback

Please [open an issue](https://github.com/IGotMikuPoster/RTVMULTIPLAYER/issues) for problems during gameplay. Include the mod/game versions, whether you were hosting or joining, Steam or direct networking, other installed mods, and steps to reproduce it. Screenshots and relevant logs help; remove private addresses or other personal information before posting.

You can also contact me on Discord: **kazmerx**, or leave a comment on the ModWorkshop mod page.

## Source and license

The source includes the game-side scripts and Go Steam companion. Compiled executables, Steam API binaries, game assets, personal saves, and temporary build files are not included. Use a packaged release to play; the source alone is not install-ready.

Internal folder names and identifiers are retained for compatibility with existing saves and the mod loader. See [LICENSE](LICENSE) and [third-party notices](THIRD_PARTY_NOTICES.md). This is an unofficial mod, not endorsed by Road to Vostok Ltd. or Valve.
