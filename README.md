# winget-manifests
manifests for winget

- https://github.com/siakhooi/json2table
- https://github.com/siakhooi/jexl-executor
- https://github.com/siakhooi/semvery
- https://github.com/siakhooi/picsum

## Bump latest releases

`script/bump.ps1` runs on Windows (locally or GitHub Actions). It syncs the
[siakhooi/winget-pkgs](https://github.com/siakhooi/winget-pkgs) fork, copies each
app's previous manifest, writes the latest GitHub release, submits a PR with
`wingetcreate.exe`, and commits the new files in this repo.

```powershell
.\script\bump.ps1                     # all packages
.\script\bump.ps1 jexl-executor       # one or more packages
.\script\bump.ps1 -DryRun
.\script\bump.ps1 -SkipSubmit         # local manifests only
.\script\bump.ps1 -Commit             # commit local files (Actions always commits)
```

A GitHub Action runs daily at 04:00 Malaysia time. Add a repository secret
`WINGET_TOKEN`: a **classic** PAT with `public_repo`, from the account that
owns the `siakhooi/winget-pkgs` fork.
