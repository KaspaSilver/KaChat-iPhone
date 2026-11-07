#!/bin/sh
#
# Xcode Cloud runs this after cloning the repo, before the build starts.
#
# Build numbers are NOT set here any more. This script used to stamp every target with Xcode
# Cloud's $CI_BUILD_NUMBER so the app and its extensions matched (App Store Connect rejects
# an archive where they differ); that job moved to ci_pre_xcodebuild.sh, which stamps the
# number from KaChat/Version.xcconfig instead - see the reasoning there.
#
# Nothing else to do here since Swap (and the API key this used to write) left the app.

set -e
