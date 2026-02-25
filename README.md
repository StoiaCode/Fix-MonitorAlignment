# Fix-MonitorAlignment

A PowerShell script that detects and fixes sub-pixel monitor alignment discrepancies in the Windows registry.

## The Problem

Windows stores monitor positions as pixel coordinates in the registry. When you arrange monitors via **Settings > Display**, the drag-and-drop UI works well enough for simple setups — two monitors side by side, one on top of the other, etc. As long as each monitor only shares **one border** with another monitor, the UI can place them precisely.

The problems start when a monitor shares **two or more borders** with neighboring monitors. This is most common in:

- **Triangle / reverse pyramid setups** (e.g. ultrawide on the bottom, two monitors on top)
- **2x2 grids** and larger arrangements
- **Any layout where three or more monitors meet at a corner**

In these setups, the UI lets you drag monitors into approximate position, but it regularly introduces **tiny offsets of 1–5 pixels** between monitors that are supposed to be aligned. You can't see this in the UI — everything looks perfectly lined up. But the coordinates tell a different story.

The result: your mouse cursor hits an invisible wall or dead zone at the boundary between two monitors that *should* be flush. The cursor gets stuck for a moment, or you have to nudge it up/down a few pixels to cross the border. Once you know it's there, it's infuriating.

This is **not fixable through the Display Settings UI**. The visual snapping grid simply doesn't have the precision to guarantee pixel-perfect alignment across more than one shared border. The only fix is editing the registry values directly — which is what this script does.

## What It Does

1. Finds the most recent monitor configuration in the registry (by timestamp)
2. Reads all monitor positions and resolutions
3. Detects monitors whose positions are *almost* aligned (within a configurable threshold) but off by a few pixels
4. Groups them into alignment clusters and proposes corrections
5. Asks for confirmation before writing any changes

## Usage

Run as **Administrator** in PowerShell:

```powershell
.\Fix-MonitorAlignment.ps1
```

With a custom alignment threshold (default is 10px):

```powershell
.\Fix-MonitorAlignment.ps1 -Threshold 5
```

### Example Output

```
Most recent config: DELA216...+BNQ7F766...+BNQ78D6...
Timestamp: 25.02.2026 21:00:44

Found 3 monitors:

  [1] 00 — 3440x1440 @ (0, 0)
  [2] 01 — 2560x1440 @ (-298, -1440)
  [3] 02 — 2560x1440 @ (2262, -1442)

=== Proposed corrections (threshold: 10px) ===

  02: vertical -1442 -> -1440 (+2px)

Apply these corrections? (y/n):
```

## How It Works

The script reads from:

```
HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Configuration
```

Each configuration entry contains numbered subkeys (00, 01, 02, ...) representing individual monitor outputs. Each subkey holds `Position.cx` / `Position.cy` (coordinates) and `PrimSurfSize.cx` / `PrimSurfSize.cy` (resolution).

The alignment detection uses a clustering approach: if two or more monitors have positions within the threshold on the same axis, they're assumed to be *intended* to be aligned and the script offers to snap them to a common value (the median of the cluster).

## Requirements

- Windows 10 / 11
- PowerShell 5.1+
- Administrator privileges (registry write access)
- Multi-monitor setup (3+)

## Notes

- The script only modifies position values, never resolution or other display settings.
- A reboot or sign-out/sign-in may be needed for changes to take effect.
- Changes may be overwritten if you rearrange monitors in Display Settings afterwards. Just run the script again.
- Works with any number of monitors and any combination of resolutions.

## License

MIT
