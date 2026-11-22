# Release checklist

For maintainers. Work through it in order for each release. **Nothing is tagged or published until the owner approves (step 5).**

Replace `<version>` below with the version being released (for example `0.2.0`). Its release notes are that version's entry in [`CHANGELOG.md`](../CHANGELOG.md).

## 1. The code is ready

- [ ] `$script:ToolVersion` in `src/Convert-UiPathToDrawio.ps1` matches the version being released.
- [ ] The `CHANGELOG.md` entry for this version is complete. Until the release is approved it says "release candidate, not yet released".
- [ ] All tests pass in both PowerShell versions:
  ```powershell
  pwsh -NoProfile -File .\tests\Test-Converter.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Converter.ps1
  ```
- [ ] The compatibility run is complete: 93 of 93 projects converted, identical output in both versions, no diagram check problems.
  ```powershell
  pwsh -File .\tests\compatibility\Invoke-CompatibilityRun.ps1
  ```
- [ ] `docs/compatibility-report.md` reflects that run. Any change from the previous run is explained.
- [ ] No real or third-party workflow content in the repository: `git status` shows nothing from `private/` or `output/`, and fixtures and samples are made up.
- [ ] Everything is committed and pushed. The release is made from a commit on `main`.

## 2. The documents are right

- [ ] README: the quick start works exactly as written (step 4 checks this), and the supported-content table, limitations and screenshots match the release.
- [ ] `docs/usage.md` matches the behaviour, including the report sections and legend.
- [ ] Links between documents work.
- [ ] `CONTEXT.md` records the decisions made since the last release.

## 3. Build the download

Build the archive from the tag, so it holds exactly the tagged commit. Create the tag locally first (`git tag -a v<version> -m "uipath-to-drawio <version>"`), and push it only in step 6. Building twice from the same tag gives the same checksum.

```bash
git archive --format=zip --prefix=uipath-to-drawio-<version>/ -o uipath-to-drawio-<version>.zip v<version> src samples docs README.md LICENSE CHANGELOG.md
h=$(sha256sum uipath-to-drawio-<version>.zip | cut -d' ' -f1)
printf '%s  uipath-to-drawio-<version>.zip\n' "$h" > uipath-to-drawio-<version>.zip.sha256
```

If a gate fails before publishing, delete the local tag (`git tag -d v<version>`), fix the problem, and start again.

- [ ] The archive holds `src`, `samples`, `docs`, `README.md`, `LICENSE` and `CHANGELOG.md`, and nothing from `tests`, `private` or `output`.
- [ ] Keep the archive and its `.sha256` file out of the repository.

## 4. Check it on a clean copy

On a machine or user account that has not run the tool before, if possible. Otherwise use a new, empty folder.

- [ ] Extract the archive into an empty folder, check the hash (`Get-FileHash`), and unblock the script as the README says.
- [ ] Run the README quick start in **Windows PowerShell 5.1**, then again in **PowerShell 7**, into separate output folders. Both runs exit with code 0 and write the two files the README names.
- [ ] The two runs' `.drawio` files are byte-identical.
- [ ] The diagram opens in the draw.io desktop app. Every page shows, and the project map's links open the workflow pages. A command-line export proves the file parses:
  ```powershell
  & "$env:LOCALAPPDATA\Programs\drawio\app\draw.io.exe" -x -f png -p 1 -o map.png .\output\demo\OrderIntakeDemo.drawio
  ```
- [ ] The report says `Version:  <version>`.
- [ ] `Get-Help .\src\Convert-UiPathToDrawio.ps1 -Full` shows the help.

## 5. Approval

- [ ] The owner has reviewed the results of steps 1 to 4 and approved the release. **Stop here until then.**

## 6. Publish (after approval only)

```powershell
git push origin main
git push origin v<version>
gh release create v<version> .\uipath-to-drawio-<version>.zip .\uipath-to-drawio-<version>.zip.sha256 --title "uipath-to-drawio <version>" --notes-file <notes>
```

- [ ] The release notes are the `CHANGELOG.md` entry for the version, plus the archive's SHA-256 checksum.
- [ ] Before tagging, date the `CHANGELOG.md` heading. The README's "Get the tool" step already points at the latest release.
- [ ] Download the published archive once and check its hash against the `.sha256` file.
