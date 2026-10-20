#!/usr/bin/env bash
# test-generic-conformance.sh - Generic repository (raw file storage) conformance tests
#
# Validates that the generic repository handles file uploads, downloads,
# nested paths, content integrity, 404 for missing files, and that a stored
# path cannot be overwritten (409).
#
# Endpoints: ${BASE_URL}/api/v1/repositories/{repo_key}/ (management API)
#
# The generic format has no format-native handler. All operations use the
# standard artifact management API for upload and download.
#
# Requires: jq, shasum
source "$(dirname "$0")/../lib/common.sh"

begin_suite "generic-conformance"
auth_admin
setup_workdir

REPO_KEY="test-generic-conf-${RUN_ID}"

# ---------------------------------------------------------------------------
# Create repository
# ---------------------------------------------------------------------------

begin_test "Create generic local repository"
if create_local_repo "$REPO_KEY" "generic"; then
  pass
else
  fail "could not create generic repository"
fi

# ---------------------------------------------------------------------------
# 1. PUT /{path} uploads a file
# ---------------------------------------------------------------------------

begin_test "Upload file via PUT"
echo "generic conformance test content" > "${WORK_DIR}/testfile.txt"
ORIG_SHA256=$(shasum -a 256 "${WORK_DIR}/testfile.txt" | awk '{print $1}')

if api_upload "/api/v1/repositories/${REPO_KEY}/artifacts/tools/v1/testfile.txt" \
    "${WORK_DIR}/testfile.txt" "text/plain" > /dev/null; then
  pass
else
  fail "file upload returned non-2xx"
fi

# ---------------------------------------------------------------------------
# 2. GET /{path} downloads the file
# ---------------------------------------------------------------------------

begin_test "Download file via GET"
if curl -sf $CURL_TIMEOUT \
    -H "$(auth_header)" \
    -o "${WORK_DIR}/downloaded.txt" \
    "${BASE_URL}/api/v1/repositories/${REPO_KEY}/download/tools/v1/testfile.txt"; then
  if [ -s "${WORK_DIR}/downloaded.txt" ]; then
    pass
  else
    fail "downloaded file is empty"
  fi
else
  fail "file download returned non-2xx"
fi

# ---------------------------------------------------------------------------
# 3. PUT with nested path (foo/bar/baz.txt)
# ---------------------------------------------------------------------------

begin_test "Upload file with deeply nested path"
echo "deeply nested content for conformance test" > "${WORK_DIR}/nested.txt"

if api_upload "/api/v1/repositories/${REPO_KEY}/artifacts/foo/bar/baz/nested.txt" \
    "${WORK_DIR}/nested.txt" "text/plain" > /dev/null; then
  # Verify it can be downloaded
  if curl -sf $CURL_TIMEOUT \
      -H "$(auth_header)" \
      -o "${WORK_DIR}/nested-dl.txt" \
      "${BASE_URL}/api/v1/repositories/${REPO_KEY}/download/foo/bar/baz/nested.txt"; then
    if [ -s "${WORK_DIR}/nested-dl.txt" ]; then
      pass
    else
      fail "downloaded nested file is empty"
    fi
  else
    fail "nested file download returned non-2xx"
  fi
else
  fail "nested path upload returned non-2xx"
fi

# ---------------------------------------------------------------------------
# 4. Download integrity matches upload
# ---------------------------------------------------------------------------

begin_test "Download integrity matches upload (SHA256)"
if [ -s "${WORK_DIR}/downloaded.txt" ]; then
  DL_SHA256=$(shasum -a 256 "${WORK_DIR}/downloaded.txt" | awk '{print $1}')
  if assert_eq "$DL_SHA256" "$ORIG_SHA256" "SHA256 mismatch after round-trip: expected ${ORIG_SHA256}, got ${DL_SHA256}"; then
    pass
  fi
else
  skip "no downloaded file to verify"
fi

# ---------------------------------------------------------------------------
# 5. 404 for nonexistent path
# ---------------------------------------------------------------------------

begin_test "404 for nonexistent path"
status=$(curl -s -o /dev/null -w '%{http_code}' $CURL_TIMEOUT \
  -H "$(auth_header)" \
  "${BASE_URL}/api/v1/repositories/${REPO_KEY}/download/does/not/exist.bin") || true
if assert_eq "$status" "404" "expected 404 for nonexistent path, got ${status}"; then
  pass
fi

# ---------------------------------------------------------------------------
# 6. Re-upload: PUT to a stored path is refused and keeps the original
#
# A generic path is write-once: the backend answers a second PUT to a live
# path with 409 CONFLICT ("Artifact version already exists and is immutable")
# and serves the original bytes, whatever the new bytes are. This is the
# always-on rule (no repository setting), so it holds with any release-
# immutability policy off. A repository with versioning_enabled appends a
# revision instead; this suite's repository does not set it.
# ---------------------------------------------------------------------------

begin_test "Re-upload of a stored path is refused with 409 and keeps the original"
echo "original content for re-upload test" > "${WORK_DIR}/reupload.txt"
ORIG_REUPLOAD_SHA=$(shasum -a 256 "${WORK_DIR}/reupload.txt" | awk '{print $1}')
echo "replacement content for re-upload test -- different bytes" > "${WORK_DIR}/reupload-v2.txt"
REUPLOAD_URL="${BASE_URL}/api/v1/repositories/${REPO_KEY}/artifacts/reupload-test/data.txt"

if ! api_upload "/api/v1/repositories/${REPO_KEY}/artifacts/reupload-test/data.txt" \
    "${WORK_DIR}/reupload.txt" "text/plain" > /dev/null; then
  fail "original upload returned non-2xx"
else
  status=$(curl -s -o "${WORK_DIR}/reupload-resp.json" -w '%{http_code}' $CURL_TIMEOUT -X PUT \
    -H "$(auth_header)" \
    -H "Content-Type: text/plain" \
    --data-binary "@${WORK_DIR}/reupload-v2.txt" \
    "$REUPLOAD_URL") || true
  if assert_eq "$status" "409" "re-upload to a stored path should return 409, got ${status}: $(head -c 200 "${WORK_DIR}/reupload-resp.json" 2>/dev/null)"; then
    if curl -sf $CURL_TIMEOUT \
        -H "$(auth_header)" \
        -o "${WORK_DIR}/reupload-dl.txt" \
        "${BASE_URL}/api/v1/repositories/${REPO_KEY}/download/reupload-test/data.txt"; then
      DL_SHA=$(shasum -a 256 "${WORK_DIR}/reupload-dl.txt" | awk '{print $1}')
      if assert_eq "$DL_SHA" "$ORIG_REUPLOAD_SHA" "a refused re-upload must leave the original content in place"; then
        pass
      fi
    else
      fail "download after refused re-upload returned non-2xx"
    fi
  fi
fi

end_suite
