# GTD Island

A floating macOS panel that answers "where do I start?" from a Notion GTD database, and jumps to the right session or page.

Status: proof of concept. The UI is in Traditional Chinese.

## Requirements

- macOS 14, Swift 5.9
- [uv](https://github.com/astral-sh/uv) for the session finder
- A Notion integration that can read your GTD Items and Time Log data sources

## Setup

1. Store the Notion token in Keychain. The command prompts for it, so it stays out of your shell history:

   ```bash
   security add-generic-password -s gtd-island-notion -a "$USER" -w
   ```

2. Create `~/.gtd-island/config.json` with your own IDs:

   ```json
   {
     "dataSource": "<GTD Items data source ID>",
     "timeLog": "<Time Log data source ID>",
     "view": "view://<view ID>",
     "tabs": [
       {"name": "Work", "areas": ["Client Work"]},
       {"name": "Reading", "areas": ["Reading"], "titlePrefixes": ["Book club"], "linkContains": ["reading-notes"]}
     ],
     "thirdSlot": "Reading"
   }
   ```

   `tabs` and `thirdSlot` are optional. A tab collects the Projects whose Area is in `areas`. `titlePrefixes` matches the title, and `linkContains` matches `Worktree` or `Source URL`; both win over `areas`. Projects that match no tab appear under 其他. `thirdSlot` is the tab that keeps the third place of 先看這 3 件 until you choose another. Restart the panel after you edit this file.

3. Build, install and start the panel:

   ```bash
   scripts/install.sh
   ```

The session finder also needs an ONNX export of `multilingual-e5-small` in `~/.gtd-island/models/multilingual-e5-small/`. The other tabs work without it.

## Tests

```bash
swift test
```

```bash
cd scripts && python3 -m unittest test_refresh test_route
```

The expected Notion properties and panel behavior are in [docs/spec.md](docs/spec.md).

## License

[MIT](LICENSE)
