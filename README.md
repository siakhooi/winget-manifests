# winget-manifests
manifests for winget

- https://github.com/siakhooi/json2table
- https://github.com/siakhooi/jexl-executor
- https://github.com/siakhooi/semvery
- https://github.com/siakhooi/picsum

## Bump latest releases

`script/bump.sh` checks each package's GitHub latest release, writes a new
manifest version, and opens a PR against [microsoft/winget-pkgs](https://github.com/microsoft/winget-pkgs)
via [komac](https://github.com/russellbanks/Komac) (Linux).

```bash
./script/bump.sh                  # all packages
./script/bump.sh jexl-executor    # one or more packages
./script/bump.sh --dry-run
./script/bump.sh --skip-submit    # local manifests only
```

A GitHub Action runs daily at 04:00 Malaysia time. Add a repository secret
`WINGET_TOKEN`: a **classic** PAT with `public_repo`, from an account that has
a fork of `microsoft/winget-pkgs`.
