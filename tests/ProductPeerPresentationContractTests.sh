#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
SOURCE="$ROOT/skills/codex-recent-tasks-sidebar/assets/app-template/Codex最近任务栏.swift"

fail() {
  print -u2 "PRODUCT_PEER_PRESENTATION_FAILED $1"
  exit 1
}

/usr/bin/grep -Fq 'struct DiscoveredProductSectionView: View' "$SOURCE" \
  || fail "missing peer product section"

if /usr/bin/grep -Fq 'struct DiscoveredProductsSectionView: View' "$SOURCE"; then
  fail "legacy grouped product section remains"
fi

for forbidden_copy in \
  'Text("首批 Cowork")' \
  'Text("元数据模式")' \
  'Text("待适配")'; do
  if /usr/bin/grep -Fq "$forbidden_copy" "$SOURCE"; then
    fail "visible explanatory copy remains: $forbidden_copy"
  fi
done

product_section="$(
  /usr/bin/awk '
    /struct DiscoveredProductSectionView: View/ { capture = 1 }
    /struct LocalAIStatusView: View/ { capture = 0 }
    capture { print }
  ' "$SOURCE"
)"

[[ "$product_section" == *'Text(snapshot.descriptor.displayName)'* ]] \
  || fail "missing product name"
[[ "$product_section" == *'Text(presentation.statusText)'* ]] \
  || fail "runtime status is not directly visible"
[[ "$product_section" == *'.font(.system(size: 11, weight: .semibold))'* ]] \
  || fail "product name does not match agent heading typography"
[[ "$product_section" == *'snapshot.officialBrandMarkPath'* ]] \
  || fail "official bundled product mark is not preferred"
[[ "$product_section" == *'NSImage(contentsOfFile:'* ]] \
  || fail "official bundled product mark is not loaded"
[[ "$product_section" == *'NSWorkspace.shared.icon(forFile:'* ]] \
  || fail "installed application icon fallback is missing"
[[ "$product_section" == *'Image(nsImage:'* ]] \
  || fail "product icon is still a generic symbol"
[[ "$product_section" == *'snapshot.quotaSummary ?? "余额 —"'* ]] \
  || fail "missing product balance slot"
[[ "$product_section" == *'ForEach(snapshot.threads)'* ]] \
  || fail "missing product thread list"
[[ "$product_section" == *'Text(snapshot.activeTaskCount.map(String.init) ?? "—")'* ]] \
  || fail "missing active thread count"

/usr/bin/grep -Fq 'ForEach(discoveryStore.snapshots)' "$SOURCE" \
  || fail "products are not rendered as peers"

print "PRODUCT_PEER_PRESENTATION_OK products=peer icons=official runtime_status=visible threads=present quota_slot=present visible_copy=minimal"
