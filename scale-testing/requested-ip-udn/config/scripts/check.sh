#!/bin/sh

# kube-burner evaluates beforeCleanup files with /bin/sh and sets the
# scenario directory as the working directory. Hand off to the Bash
# implementation explicitly because it uses arrays and strict mode.
exec bash config/scripts/check-bash.sh "$@"
