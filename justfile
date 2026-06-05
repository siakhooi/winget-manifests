setup:
    winget.exe install wingetcreate

# as System Administrator
enable:
    winget.exe settings --enable LocalManifestFiles

#
#  New
#
new:
    wingetcreate.exe new

#
# Next Release
#
update:
    wingetcreate.exe update --urls "{{ packageUrl }}|x64" --version "{{ packageVersion }}"   {{ Author }}.{{ PackageName }}
