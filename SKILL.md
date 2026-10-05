---
name: claude-dual-account
description: Dual account setup for the Claude desktop app. Makes two Claude accounts (for example a personal and a work account) share one Code tab session list, on Windows and on macOS, so switching account in the app keeps every session and its full context. Use this whenever the user wants both Claude accounts to see the same sessions or the same sidebar, mentions a dual account or two-account setup, says that switching account in Claude Desktop hides their sessions, asks to merge, share or sync Claude Code sessions between accounts on one computer, or wants to check, repair, update or undo that setup.
---

# Claude Dual Account: one sidebar for two accounts (Windows and macOS)

Scope: one computer, two Claude accounts, the Code tab session list only.

## How it works

- Claude Code stores every conversation transcript once on the computer (`~/.claude/projects`), whatever account wrote it.
- The Claude desktop app keeps the Code tab sidebar (the session list) separately per account and org, in `claude-code-sessions/<account uuid>/<org uuid>/`, one `local_<id>.json` per session. Switching account switches the list, even though every conversation is still on disk.
  - Windows (Store install): `%LOCALAPPDATA%\Packages\Claude_*\LocalCache\Roaming\Claude\claude-code-sessions`
  - Windows (classic install, detected but untested): `%APPDATA%\Claude\claude-code-sessions`
  - macOS: `~/Library/Application Support/Claude/claude-code-sessions`
- The sync script copies the other account folders' session entries into one shared folder and replaces those folders with links to it (junctions on Windows, symlinks on macOS). Both accounts then read and write the same list.
- A repair job runs the script in heal mode every 10 minutes: a scheduled task on Windows, a LaunchAgent on macOS. If an app update puts a real folder back in place of a link, it merges the new entries and links it again. On anything it does not recognize it changes nothing and writes an alert file.
- Tested on Windows 11 Pro (Store app, the same session continued on the other account and back) and on macOS 27 (both accounts show the same list). Unofficial: Anthropic does not document this layout, so an update can change it.

## Before you start

Explain to the user, in their language and briefly:
- Both accounts will share one session list. Nothing is deleted: a backup is made and the original folders are kept under a new name.
- Only the session list is shared. Everything else stays with each account.
- When a session continues on the other account, its whole history goes to that account. With a work account that is the user's data-handling call.

Wait for a clear go before applying.

## Which script

Check the operating system first. All paths below are inside this skill's folder, use them as absolute paths.
- Windows: `scripts/windows/claude-sidebar-sync.ps1` and `scripts/windows/claude-sidebar-sync-task.ps1`, run as `powershell -NoProfile -ExecutionPolicy Bypass -File "<path>" <options>`.
- macOS: `scripts/macos/claude-sidebar-sync.sh`, run as `bash "<path>" <options>`.

| Step | Windows | macOS |
| - | - | - |
| Report (read-only) | no options | no options |
| Apply | `-Apply` | `--apply` |
| Pick the shared folder | `-Primary '<account>\<org>'` | `--primary <account>/<org>` |
| Repair job | `claude-sidebar-sync-task.ps1 -Apply` (elevated) | `--install-agent` |
| Undo | `-Rollback`, then task script `-Remove` (elevated) | `--rollback`, then `--remove-agent` |

## Steps (same on Windows and macOS)

1. **Check that both accounts have a folder.** An account appears only after it signed in to the desktop app once on this computer. If the report shows one account, ask the user to sign in to the second account once, open the Code tab, then switch back.
2. **Report.** Run the sync script with no options and show the user what it found: the account folders, the shared folder, and what would be copied and linked.
   - The shared folder defaults to the account the app is signed in to right now, because that folder is in use and must stay a real folder. Claude running inside the desktop app knows that account from the environment.
   - When the script cannot tell (run from a plain terminal), it picks the folder with the most sessions, and on macOS it refuses to apply while the Claude app runs. Then the user quits the app (Cmd+Q) and runs the apply command in Terminal.
   - More than 2 accounts: Windows takes `-Accounts uuid1,uuid2`. The macOS script stops, tell the user.
3. **Apply** after the user's go, and show the log lines. If it refuses because the app is signed in to an account whose folder would be replaced, ask the user to switch the app to the shared account, or to quit the app and run the command in a terminal.
4. **Test with the user.** In the app: sign out, sign in to the other account, check the sidebar shows the same sessions, open one and send a short message, switch back and check it is there. Signing out stops the current conversation, which is expected.
5. **Repair job.** This changes system configuration, so ask first.
   - Windows: the user runs, from an elevated PowerShell (Run as administrator): `powershell -NoProfile -ExecutionPolicy Bypass -File "<skill folder>\scripts\windows\claude-sidebar-sync-task.ps1" -Apply`. Check with the same script and no options: last result `0x0`, no alert file.
   - macOS: no admin needed, run `--install-agent` with the user's OK, then check `launchctl print gui/$(id -u)/local.claude-sidebar-sync` shows `last exit code = 0`.
   - The job points at this skill folder. If the folder moves, run the job step again.

## Where things are

- Data folder: `%USERPROFILE%\ClaudeSharedSidebar` on Windows, `~/ClaudeSharedSidebar` on macOS, with the saved choices (config), `logs/claude-sidebar-sync.log`, `backups/<time>/`, and `ALERT-claude-sidebar-sync.txt` when something needs a person.
- The original folders stay next to the links, renamed to `<org uuid>.pre-merge-<time>`.
- A healthy heal run writes nothing to the log.

## When something breaks

- Read the alert file and the log first. The repair job never guesses: on an unknown layout, a link that points elsewhere, a new org folder, or more than 3 repairs in a day, it stops and writes the alert.
- A new org folder (the alert says so): run apply again to include it.
- Undo restores each account's original list plus any later entries and turns the repair off. Remove the repair job too (see the table).
- Never delete these links recursively. On Windows, `Remove-Item -Recurse` in PowerShell 5.1 follows a junction and deletes the shared folder's files. On macOS, `rm -rf <link>/` with a trailing slash does the same. The scripts remove only the link itself, so use their undo option. Some agent harnesses block typing `cmd /c rmdir` directly, another reason to use the undo option.
- If the app moved its storage after an update (no `claude-code-sessions` folder, or a shared folder with no entries), stop and tell the user. Do not invent a new layout.

## Updates

- Source and issues: https://github.com/RonenBinyaminov/claude-dual-account
- A git install updates with `git pull` in this folder. The repair job keeps working because the folder does not move.

## Ground rules for Claude

- The scripts only touch the sidebar folders and their own data folder. They never read, print or send a credential and never touch the transcripts. Keep it that way.
- Do not apply without the user's go. Do not register, install or remove the repair job without asking. On Windows the user runs that step.
