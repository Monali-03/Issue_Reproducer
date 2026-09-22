#!/usr/bin/env bash
# prepare-app.sh — materialise a test application for this case and build it.
#
# Called by setup.sh. Picks the servlet/Jakarta namespace from the product major, so the
# same source tree builds correctly for EAP 7.x and EAP 8.x.
#
# The javax -> jakarta boundary is the most expensive trap in this product family: a WAR
# built against javax.servlet DEPLOYS SUCCESSFULLY on EAP 8 and reports healthy in the
# management console, while every servlet returns 404 because the annotations are never
# scanned. That is why setup.sh builds and start.sh then CALLS the endpoint.
#
# Usage: prepare-app.sh <blueprint> <dest-dir>
#   blueprint: session-cluster | simple-web
# Reads TARGET_MAJOR, TARGET_JDK, APP_NAME from the environment (nodes.env).

set -euo pipefail

BLUEPRINT="${1:?usage: prepare-app.sh <blueprint> <dest-dir>}"
DEST="${2:?usage: prepare-app.sh <blueprint> <dest-dir>}"
TPL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

: "${TARGET_MAJOR:?TARGET_MAJOR must be set (from nodes.env)}"
: "${TARGET_JDK:=11}"
: "${APP_NAME:=repro}"

[[ -d "$TPL_DIR/$BLUEPRINT" ]] || { echo "unknown blueprint: $BLUEPRINT" >&2; exit 1; }

# --- namespace selection ----------------------------------------------------
case "$TARGET_MAJOR" in
  7)
    NS="javax"
    SERVLET_GROUP="javax.servlet"
    SERVLET_ARTIFACT="javax.servlet-api"
    SERVLET_VERSION="4.0.1"
    WEBXML_NS="http://xmlns.jcp.org/xml/ns/javaee"
    WEBXML_XSD="http://xmlns.jcp.org/xml/ns/javaee/web-app_4_0.xsd"
    WEBXML_VERSION="4.0"
    ;;
  8|9)
    NS="jakarta"
    SERVLET_GROUP="jakarta.servlet"
    SERVLET_ARTIFACT="jakarta.servlet-api"
    SERVLET_VERSION="6.0.0"
    WEBXML_NS="https://jakarta.ee/xml/ns/jakartaee"
    WEBXML_XSD="https://jakarta.ee/xml/ns/jakartaee/web-app_6_0.xsd"
    WEBXML_VERSION="6.0"
    ;;
  *)
    echo "prepare-app.sh: unsupported TARGET_MAJOR='$TARGET_MAJOR'." >&2
    echo "Add its namespace mapping here rather than guessing one." >&2
    exit 1
    ;;
esac

echo "prepare-app: blueprint=$BLUEPRINT major=$TARGET_MAJOR namespace=$NS.* jdk=$TARGET_JDK"

# --- materialise ------------------------------------------------------------
rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
cp -r "$TPL_DIR/$BLUEPRINT" "$DEST"

while IFS= read -r -d '' f; do
  sed -i \
    -e "s|__NS__|$NS|g" \
    -e "s|__SERVLET_GROUP__|$SERVLET_GROUP|g" \
    -e "s|__SERVLET_ARTIFACT__|$SERVLET_ARTIFACT|g" \
    -e "s|__SERVLET_VERSION__|$SERVLET_VERSION|g" \
    -e "s|__WEBXML_NS__|$WEBXML_NS|g" \
    -e "s|__WEBXML_XSD__|$WEBXML_XSD|g" \
    -e "s|__WEBXML_VERSION__|$WEBXML_VERSION|g" \
    -e "s|__JDK__|$TARGET_JDK|g" \
    -e "s|__APP_NAME__|$APP_NAME|g" \
    "$f"
done < <(find "$DEST" -type f \( -name '*.java' -o -name '*.xml' \) -print0)

# Fail loudly on an unsubstituted token rather than shipping a broken WAR.
if grep -rqE '__[A-Z_]+__' "$DEST"; then
  echo "prepare-app: unsubstituted tokens remain:" >&2
  grep -rnoE '__[A-Z_]+__' "$DEST" | sort -u >&2
  exit 1
fi

echo "prepare-app: materialised $DEST"

# Well-formedness check on every descriptor. EAP treats a malformed web.xml as a PARSE-phase
# failure but still logs WFLYSRV0010 "Deployed", so the WAR looks deployed while every
# request 404s — indistinguishable from the namespace trap above unless it is caught here.
xml_ok() {
  if command -v xmllint >/dev/null 2>&1; then xmllint --noout "$1" 2>&1
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import sys,xml.dom.minidom as m; m.parse(sys.argv[1])' "$1" 2>&1
  else return 0; fi
}
while IFS= read -r -d '' f; do
  if ! err="$(xml_ok "$f")"; then
    echo "prepare-app: $f is not well-formed XML:" >&2
    echo "$err" >&2
    exit 1
  fi
done < <(find "$DEST" -type f -name '*.xml' -print0)


# --- build ------------------------------------------------------------------
if command -v mvn >/dev/null 2>&1; then
  mvn -q -f "$DEST/pom.xml" clean package
  war="$(find "$DEST/target" -maxdepth 1 -name '*.war' | head -1)"
  [[ -n "$war" ]] || { echo "prepare-app: build produced no WAR" >&2; exit 1; }
  echo "prepare-app: built $war"
else
  echo "prepare-app: maven not found — cannot build the test application." >&2
  echo "Install maven, or supply a prebuilt WAR at $DEST/target/. BLOCKED." >&2
  exit 1
fi
