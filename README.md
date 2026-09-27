# kicad-diff

A GitHub Action that renders KiCad schematics and PCBs to SVG and commits them
next to your design, so every change shows up as an image diff on GitHub
(2-up, swipe and onion skin views in commits and pull requests).

- One SVG per schematic sheet and per PCB layer.
- Works with any repository layout: every `*.kicad_pro` found is rendered,
  including hierarchical sheets and several projects in one repository.
- Only projects whose files changed are re-rendered. Missing renders are
  created, renders of deleted or moved projects are removed.
- Output is deterministic, so a commit only contains SVGs that actually look
  different.

## Setup

Copy [`examples/kicad-svg.yml`](examples/kicad-svg.yml) to
`.github/workflows/kicad-svg.yml` in your KiCad repository.

On the next push that touches a `.kicad_sch`, `.kicad_pcb`, `.kicad_pro` or
`.kicad_wks` file, the workflow renders the design and pushes a commit
`Update KiCad SVG renders [skip ci]` to the same branch. To create the first
renders without changing anything, run the workflow from the Actions tab.

Because the bot adds a commit after yours, `git pull` before you push again.

## Output

Renders go to `kicad-svg/`, mirroring the project layout:

```
kicad-svg/
└── my-board/            # from my-board/my-board.kicad_pro
    ├── .stamp           # hash of the inputs; decides when to re-render
    ├── sch/
    │   ├── my-board.svg # root sheet
    │   └── power.svg    # one file per sub-sheet
    └── pcb/
        ├── F_Cu.svg     # one file per layer, named after the board's layer names
        ├── B_Cu.svg
        └── ...
```

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `kicad-version` | `10.0.6` | Tag of the [`kicad/kicad`](https://hub.docker.com/r/kicad/kicad) image to render with. |
| `path` | `.` | Directory to search for KiCad projects. |
| `output-dir` | `kicad-svg` | Output directory, relative to `path`. |
| `pcb-layers` | `*.Cu,F.Silkscreen,B.Silkscreen,F.Mask,B.Mask,Edge.Cuts,F.Courtyard,B.Courtyard` | PCB layers to export. Layers the board doesn't have are skipped. |
| `pcb-common-layers` | `Edge.Cuts` | Layers drawn on every PCB SVG, for orientation. |
| `force` | `false` | Re-render everything, ignoring the stamps. |
| `commit` | `true` | Commit and push the renders. |
| `commit-message` | `Update KiCad SVG renders [skip ci]` | Message of the render commit. |

Changing `kicad-version` or the layers re-renders every project once, because
both are part of the stamp. Upgrade KiCad deliberately: a new version can draw
things slightly differently, which shows up as a change on every sheet.

## Running locally

`render.sh` needs only Docker. It renders inside the same `kicad/kicad` image
the action uses, so the result is identical to CI:

```bash
./render.sh ~/path/to/kicad-repo
./render.sh --help
```

## Testing changes to the action

`test/run-act.sh` runs the example workflow end to end with
[act](https://github.com/nektos/act), without using GitHub Actions minutes. It
builds a throwaway repository from KiCad's demo projects with a local bare
repository as its remote, then checks that:

1. the first run renders and pushes every project,
2. editing one schematic only changes that project's renders,
3. a run with nothing changed pushes nothing.

```bash
./test/run-act.sh                        # act installed
nix-shell -p act --run ./test/run-act.sh # NixOS
```

It takes about 30 seconds once the Docker images are cached.

If you change `render.sh` in a way that changes its output, bump
`FORMAT_VERSION` in it so existing renders are regenerated.

## Limitations

- Runs on pushes to branches. On `pull_request` events it renders but does not
  push, and pull requests from forks can't be pushed to at all. Renders appear
  in a pull request because the bot commits to its branch.
- Sheets with a lot of text produce SVGs of 1–3 MB, since KiCad draws text as
  strokes. Git stores them compressed.
- If two branches both change a design, the SVGs can conflict when merging.
  Resolve by taking either side; the next run re-renders from the merged
  design.
