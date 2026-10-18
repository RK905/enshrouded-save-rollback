<h1 align="center">Enshrouded Save Rollback</h1>

<p align="center">
  Restore an Enshrouded Steam Cloud save by picking a backup time.<br>
  No install. Close the game, choose the save, and put an earlier copy back.
</p>

<p align="center">
  <a href="https://github.com/RK905/enshrouded-save-rollback"><img alt="Windows" src="https://img.shields.io/badge/platform-Windows-0078D4?style=flat-square"></a>
  <a href="https://github.com/RK905/enshrouded-save-rollback"><img alt="PowerShell 5.1" src="https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?style=flat-square&logo=powershell&logoColor=white"></a>
  <a href="https://store.steampowered.com/app/1203620/Enshrouded/"><img alt="Enshrouded on Steam" src="https://img.shields.io/badge/Steam-Enshrouded-171a21?style=flat-square&logo=steam&logoColor=white"></a>
  <a href="https://github.com/RK905/enshrouded-save-rollback"><img alt="Public" src="https://img.shields.io/badge/repo-public-2ea44f?style=flat-square"></a>
</p>

<p align="center">
  <img alt="Step 1, find the save" src="https://img.shields.io/badge/1-find%20the%20save-1f6feb?style=for-the-badge">
  <img alt="Step 2, pick a time" src="https://img.shields.io/badge/2-pick%20a%20time-8957e5?style=for-the-badge">
  <img alt="Step 3, restore" src="https://img.shields.io/badge/3-restore-2ea44f?style=for-the-badge">
</p>

Enshrouded keeps rolling backups of the world, the character, and global data. The backup number is only a slot. This tool reads the real file times, lists them newest first, and copies the one you choose over the live save.

When a Steam Cloud save is present, that is the list you get. The separate world under `Saved Games\keen games` is left out.

## Quick start

1. Close Enshrouded.
2. Double-click **Restore Enshrouded Save.bat**.
3. Leave the save on **Steam Cloud — World** unless you mean to roll back the character.
4. Select a time and click **Restore selected time**.
5. Restart Steam, then open the game. If Steam asks which files to use, choose the files on this PC.

> [!IMPORTANT]
> Restart Steam before you play. The restored file is given the current time so Steam keeps it. If Steam is still running from before the restore, it can put the newer cloud copy back.

The previous file is copied into a `rollback-safety-` folder next to the save before anything is replaced. The other backups stay where they are.

## What each save is

| Save | File | What it holds |
| --- | --- | --- |
| World | `world0.ksd` | Terrain, base, chests, Flame Altars |
| Character | `character0.ksd` | Level, skills, gear, inventory |
| Global data | `global.ksd` | Shared progress stored beside the world |

The world and the character are separate. Restoring the world leaves your character where it is. Restore the character only when you want that level and inventory put back too.

Empty extra world slots are hidden. A copy that matches the file already loaded is marked **Same as the current save** and cannot be restored over itself.

## Where the files are

The tool searches this PC. You do not paste a Steam ID or a path.

| Place | What it is |
| --- | --- |
| `Steam\userdata\<id>\1203620\remote` | Steam Cloud save used by the window |
| `Steam\steamapps\libraryfolders.vdf` | Extra Steam library locations |
| Proton `compatdata\1203620` | Enshrouded under Proton, when that prefix exists |
| `Saved Games\keen games\Enshrouded` | Local world. Listed only when no Steam Cloud save is found |
| A folder you pick with **Browse** | A dedicated-server `savegame` folder, or any other copy |

Version 1.0 moved older Early Access files into a `migrated` folder. The game does not load that folder, so those files are not offered.

Inside a 1.0 save, the live file sits next to a `backup` folder:

```text
remote
├── world0.ksd
├── character0.ksd
├── global.ksd
└── backup
    ├── world0.ksd.backup-0
    ├── world0.ksd.backup-1
    └── ...
```

`backup-9` is not the oldest, and `backup-0` is not the newest. The window sorts by the file's modified time.

Older saves use a hex world id and a `-index` file whose `latest` value selects slot 0 through 9. For that format the tool changes `latest` and leaves the world files in place.

## After you restore

A Steam restore does three things:

1. Copies the current file into `rollback-safety-<date-time>`.
2. Copies the backup you picked onto the live file (`world0.ksd`, `character0.ksd`, or `global.ksd`).
3. Sets that live file's modified time to now, so Steam Cloud treats it as the newer copy.

Then restart Steam. On the conflict screen, keep the files on this PC.

If the world is wrong, close the game and run the tool again. Pick another time. Playing on the wrong one writes a new backup over the oldest slot.

## Command line

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\Restore-EnshroudedSave.ps1
```

| Parameter | Effect |
| --- | --- |
| *(none)* | Open the window |
| `-List` | Print every save and timeslot, then exit |
| `-Path <folder>` | Search only that folder |
| `-Choose <n> -Slot <n>` | Restore the numbers printed by `-List` |
| `-Force` | Skip the `YES` prompt. Still stops if Enshrouded is open |

```powershell
# See the Steam Cloud times
powershell -NoProfile -ExecutionPolicy Bypass -File .\Restore-EnshroudedSave.ps1 -List

# Restore save 1, timeslot 4, from that list
powershell -NoProfile -ExecutionPolicy Bypass -File .\Restore-EnshroudedSave.ps1 -Choose 1 -Slot 4 -Force
```

`-Choose` and `-Slot` are the numbers in the list, not the `backup-` suffix.

## Requirements

- Windows with Windows PowerShell 5.1 (included with Windows 10 and 11)
- Enshrouded closed
- Your own Steam Cloud files, or a save folder you have access to

The `.bat` launcher starts PowerShell with `-STA`, which the window needs. Running the script from an existing window relaunches itself the same way.

## Project files

| File | Purpose |
| --- | --- |
| `Restore Enshrouded Save.bat` | Double-click launcher |
| `Restore-EnshroudedSave.ps1` | Search, window, and restore |

## Limits

Enshrouded keeps about ten rolling copies. That is a short history, often the last session or two, not a copy from last week. Once those slots are newer than the moment you want, the tool cannot go further back.

A dedicated server stores the world on the server. Restoring the Steam files on your PC restores your character and the cloud copy on this machine. It does not change a world that only exists on the host.
