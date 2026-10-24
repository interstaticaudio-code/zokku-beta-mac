#!/bin/bash
# REL (24 Oct 2026): copy of the packaging script of the private source repo (zokku-mac, ci/mac-package.sh) with the
# versions of the REL round; it packs bundles built there and contains no product source.
# Installer of the ZOKKU trial package for macOS: "Installa ZOKKU.pkg" (pkgbuild + productbuild, one component package
# per product and format, a curated distribution file in Italian) inside ZOKKU-Prova-<date>.dmg.
# First made on 18 Oct 2026 for the five FORMA products ("Installa FORMA.pkg"); 21 Oct 2026 (MAC2): the eleven products
# under their ZOKKU names, and the same plug-in under its old name is moved away after the install (see postinstall).
# usage: ci/mac-package.sh IN OUT [PREV] [DATE]
#   IN    folder with the ZOKKU-<NAME>-macOS.zip of the eleven products (artifacts of runs of the macOS workflow)
#   OUT   folder for the dmg, its SHA-256 and the logs
#   PREV  optional folder holding the previous trial dmg (FORMA-Prova-*.dmg): it is installed first, so the run tests
#         the upgrade a tester makes (old names in /Library, a plan-B copy in the user's folder)
#   DATE  date in the names (YYYY-MM-DD; default today)
# The bundles were signed ad-hoc and checked in the build jobs; here they are checked again (version, architectures,
# signature), packed, installed on the runner with the real installer, checked where they land, passed through auval
# from /Library, and the dmg is verified. No certificate: the pkg and the dmg are unsigned (Gatekeeper asks once).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IN="$(cd "$1" && pwd)"
mkdir -p "$2/logs"; OUT="$(cd "$2" && pwd)"; LOG="$OUT/logs"
PREV="${3:-}"; if [ -n "$PREV" ] && [ -d "$PREV" ]; then PREV="$(cd "$PREV" && pwd)"; else PREV=""; fi
DATE="${4:-}"; [ -n "$DATE" ] || DATE=$(date +%Y-%m-%d)
W="$ROOT/build/pkg"; rm -rf "$W"; mkdir -p "$W/unz" "$W/root" "$W/pkgs" "$W/res" "$W/dmg" "$W/scripts"
DMG_NAME="ZOKKU-Beta-macOS-$DATE.dmg"   # MAC3: the beta (was ZOKKU-Prova)
PKG_NAME="Installa ZOKKU.pkg"
GUIDE_PDF="Guida all'installazione.pdf"
RES="$ROOT/pkg/zokku"
BACKUP_DIR="/Library/Application Support/ZOKKU/Bundle precedenti"
FAILED=()
fail() { echo "::error title=package::$1"; FAILED+=("$1"); }
version_of() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null; }
id_of() { /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null; }

# Folder (target) | name | version | Italian description | kind | AU type and code. Order = order in the installer.
PRODUCTS="RESONANCE|TAMMO|0.14.4|Soppressore dinamico di risonanze.|effetto|aufx Rsnc
VELA|VELA|0.8.2|Delay ed eco creativo con mappa interattiva.|effetto|aufx Vela
PULSE|IKIPUMP|0.12.2|Ducking ritmico e sidechain, anche tra istanze.|effetto|aumf Puls
DENSITY|FUZZO|0.7.2|Saturazione e clipper con caratteri diversi.|effetto|aufx Dnsy
ASCENT|ASCENT|0.9.3|Riser e transizioni, con il drop sulla battuta.|effetto|aumf Asct
LOADLINE|OMOLINE|0.3.4|Finisher per beat: porta la loudness a una linea scelta, con true peak garantito.|effetto|aufx Ldln
CUTLINE|KIZAMI|0.8.2|Sampler e slicer: cue, slice e brani interi.|strumento|aumu Cutl
NINE|KITTO|0.7.2|Drum machine a campioni, 32 passi.|strumento|aumu Nine
RHYTHM|TATAKIT|0.6.2|Drum machine sintetica, sei modelli.|strumento|aumu Rytm
ORIGIN|UTSURI|0.6.5|Synth wavetable: due oscillatori, rumore, due filtri, matrice di modulazione, effetti.|strumento|aumu Orgn
GRAFT|EDAGROW|0.3.4|Synth polifonico analogico: dodici rami per suono, Grow e Graft.|strumento|aumu Grft"
# Order and names of the format choices as the guide shows them.
FORMATS="au|component|Audio Unit (AU)|/Library/Audio/Plug-Ins/Components
vst3|vst3|VST3|/Library/Audio/Plug-Ins/VST3
clap|clap|CLAP|/Library/Audio/Plug-Ins/CLAP"

# postinstall of one component package (product NAME, format F). Like the Windows installer (install-product.ps1, R1):
# once the new bundle is in place and its signature verifies, every other bundle of the same plug-in, recognised by
# its CFBundleIdentifier (audio.resonance.*, unchanged by the rename), is moved out of the plug-in folder: the FORMA
# name it had before (RESONANCE for TAMMO...) in /Library, and any copy in the plug-in folder of the user at the
# console (the plan-B zip of 18 Oct installed there), so no host lists the plug-in twice. Nothing is deleted: the
# bundles go to "$BACKUP_DIR/<date>/<original path>". A bundle with the old name but another identifier is never
# touched. The receipt of the FORMA trial package for the same product and format is forgotten.
write_postinstall() {   # TARGET NAME EXT F SUBDIR
  local f="$W/scripts/$2-$4/postinstall"; mkdir -p "$(dirname "$f")"
  cat > "$f" <<EOF
#!/bin/sh
# ZOKKU $2 ($4): the same plug-in under another name or in the user's folder is moved away (see ci/mac-package.sh).
NEW_NAME='$2'; EXT='$3'; SUB='$5'; OLD_NAME='$1'; OLD_RECEIPT='com.forma.$(echo "$1" | tr A-Z a-z).$4'; FMT='$4'
BACKUP_DIR='$BACKUP_DIR'
EOF
  cat >> "$f" <<'EOF'
VOL="${3:-/}"; VOL="${VOL%/}"
say() { echo "zokku-postinstall $NEW_NAME.$EXT: $*"; }
id_of() { /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null; }
NEW="$VOL/Library/Audio/Plug-Ins/$SUB/$NEW_NAME.$EXT"
WANT=$(id_of "$NEW")
if [ -z "$WANT" ]; then say "new bundle not readable, nothing moved"; exit 0; fi
if ! /usr/bin/codesign --verify --deep --strict "$NEW" >/dev/null 2>&1; then say "new bundle signature does not verify, nothing moved"; exit 0; fi
DAY=$(date +%Y-%m-%d)
sweep() {   # one plug-in folder
  d="$1"; [ -d "$d" ] || return 0
  for b in "$d"/*."$EXT"; do
    [ -e "$b" ] || continue
    [ "$b" = "$NEW" ] && continue
    got=$(id_of "$b")
    if [ "$got" = "$WANT" ]; then
      dst="$VOL$BACKUP_DIR/$DAY${d#$VOL}"
      [ -e "$dst/$(basename "$b")" ] && dst="$VOL$BACKUP_DIR/$DAY-$(date +%H%M%S)${d#$VOL}"
      if mkdir -p "$dst" && mv "$b" "$dst/"; then say "moved $b (same id $WANT) to $dst"; else say "could not move $b"; fi
    elif [ "$(basename "$b" ".$EXT")" = "$OLD_NAME" ]; then
      say "left $b in place: another identifier ($got)"
    fi
  done
}
sweep "$VOL/Library/Audio/Plug-Ins/$SUB"
user=$(/usr/bin/stat -f %Su /dev/console 2>/dev/null)
if [ -n "$user" ] && [ "$user" != root ] && [ "$user" != _mbsetupuser ]; then
  home=$(/usr/bin/dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | sed 's/^NFSHomeDirectory: //')
  [ -n "$home" ] && sweep "$home/Library/Audio/Plug-Ins/$SUB"
fi
if /usr/sbin/pkgutil --pkg-info "$OLD_RECEIPT" >/dev/null 2>&1; then /usr/sbin/pkgutil --forget "$OLD_RECEIPT" >/dev/null 2>&1 && say "forgot receipt $OLD_RECEIPT"; fi
if [ "$FMT" = au ]; then
  # Logic and the other AU hosts see the new Audio Units (and lose the moved ones) at once.
  killall -9 AudioComponentRegistrar 2>/dev/null || true
fi
exit 0
EOF
  chmod 755 "$f"
}

echo "::group::Bundles"
: > "$LOG/bundles.txt"
while IFS='|' read -r P NAME VER DESC KIND AU; do
  zip=$(find "$IN" -name "ZOKKU-$NAME-macOS.zip" | head -1)
  [ -n "$zip" ] || { fail "missing ZOKKU-$NAME-macOS.zip"; continue; }
  ditto -x -k "$zip" "$W/unz" || fail "unzip $NAME"
  while IFS='|' read -r F EXT FNAME DEST; do
    b="$W/unz/ZOKKU-$NAME-macOS/$NAME.$EXT"
    [ -d "$b" ] || { fail "missing $NAME.$EXT"; continue; }
    v=$(version_of "$b"); id=$(id_of "$b")
    bin="$b/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$b/Contents/Info.plist" 2>/dev/null)"
    archs=$(lipo -archs "$bin" 2>/dev/null)
    sig=$(codesign -dv "$b" 2>&1 | grep -E '^Signature=' | head -1)
    codesign --verify --deep --strict "$b" 2>>"$LOG/bundles.txt" && ok=verified || ok=INVALID
    echo "$NAME.$EXT  version $v  id $id  archs [$archs]  $sig  signature $ok" | tee -a "$LOG/bundles.txt"
    [ "$v" = "$VER" ] || fail "$NAME.$EXT version $v, want $VER"
    case "$id" in audio.resonance.*) ;; *) fail "$NAME.$EXT id $id";; esac
    case " $archs " in *" arm64 "*) ;; *) fail "$NAME.$EXT has no arm64";; esac
    case " $archs " in *" x86_64 "*) ;; *) fail "$NAME.$EXT has no x86_64";; esac
    [ "$ok" = verified ] || fail "$NAME.$EXT signature"
  done <<< "$FORMATS"
done <<< "$PRODUCTS"
echo "::endgroup::"

echo "::group::Component packages"
while IFS='|' read -r P NAME VER DESC KIND AU; do
  p=$(echo "$P" | tr A-Z a-z)
  while IFS='|' read -r F EXT FNAME DEST; do
    b="$W/unz/ZOKKU-$NAME-macOS/$NAME.$EXT"; [ -d "$b" ] || continue
    r="$W/root/$p-$F"; mkdir -p "$r"; ditto "$b" "$r/$NAME.$EXT"
    plist="$W/root/$p-$F.plist"
    pkgbuild --analyze --root "$r" "$plist" > /dev/null
    # Installed where the guide says, never "relocated" onto a copy found elsewhere on the disk.
    i=0; while plutil -extract "$i" xml1 -o /dev/null "$plist" > /dev/null 2>&1; do
      plutil -replace "$i.BundleIsRelocatable" -bool NO "$plist"; i=$((i + 1)); done
    write_postinstall "$P" "$NAME" "$EXT" "$F" "$(basename "$DEST")"
    # Package ids follow the folder, like the bundle ids, so a later rename keeps them.
    if pkgbuild --root "$r" --component-plist "$plist" --install-location "$DEST" --identifier "com.zokku.$p.$F" \
         --version "$VER" --scripts "$W/scripts/$NAME-$F" "$W/pkgs/com.zokku.$p.$F.pkg" >> "$LOG/pkgbuild.log" 2>&1; then
      echo "com.zokku.$p.$F ($NAME.$EXT) -> $DEST"
    else tail -5 "$LOG/pkgbuild.log"; fail "pkgbuild $p.$F"; fi
  done <<< "$FORMATS"
done <<< "$PRODUCTS"
cp "$W/scripts/TAMMO-vst3/postinstall" "$LOG/postinstall-TAMMO-vst3.sh" 2>/dev/null
echo "::endgroup::"

echo "::group::Resources"
# Pages and background of the ZOKKU installer (pkg/zokku, made from the FORMA guide's pages of 18 Oct). The welcome page
# gets the product list and the date; the licence page always ends with the two font licences (added when it lacks them).
for n in welcome conclusion license; do cp "$RES/$n.html" "$W/res/$n.html" || fail "missing pkg/zokku/$n.html"; done
python3 - "$W/res/welcome.html" "$DATE" "$PRODUCTS" <<'EOF'
import html, sys
page, date, products = sys.argv[1:4]
months = ['gennaio','febbraio','marzo','aprile','maggio','giugno','luglio','agosto','settembre','ottobre','novembre','dicembre']
y, m, d = (int(x) for x in date.split('-'))
items = []
for line in products.splitlines():
    p, name, ver, desc, kind, au = line.split('|')
    desc = desc.rstrip('.'); desc = desc[:1].lower() + desc[1:]
    items.append('<li><b>%s</b> <span class="v">%s</span> · %s</li>' % (html.escape(name), ver, html.escape(desc)))
s = open(page, encoding='utf-8').read()
assert '<!--PRODUCTS-->' in s and '<!--DATE-->' in s
s = s.replace('<!--PRODUCTS-->', '<ul>\n' + '\n'.join(items) + '\n</ul>').replace('<!--DATE-->', '%d %s %d' % (d, months[m - 1], y))
open(page, 'w', encoding='utf-8').write(s)
print('welcome.html: %d products, date %d %s %d' % (len(items), d, months[m - 1], y))
EOF
[ $? -eq 0 ] || fail "welcome page"
cp "$RES/pkg-background.png" "$W/res/background.png" || fail "missing background"
cp "$RES/pkg-background-dark.png" "$W/res/background-dark.png" || fail "missing dark background"
python3 - "$W/res/license.html" "$ROOT/pkg/licenses/CabinetGrotesk-FFL.txt" "$ROOT/pkg/licenses/Geist-OFL.txt" <<'EOF'
import html, re, sys
page, ffl, ofl = sys.argv[1:4]
s = open(page, encoding='utf-8').read()
blocks = []
for title, path, marker in (("Cabinet Grotesk — ITF Free Font License (FFL) 2.0", ffl, "ITF Free Font License"),
                            ("Geist e Geist Mono — SIL Open Font License 1.1", ofl, "SIL OPEN FONT LICENSE")):
    if marker.lower() in s.lower():
        print("license.html already has", marker); continue
    text = open(path, encoding='utf-8').read()
    blocks.append('<h2>%s</h2>\n<pre>%s</pre>\n' % (html.escape(title), html.escape(text)))
add = ''.join(blocks)
if add:
    if re.search(r'</body>', s, re.I): s = re.sub(r'</body>', lambda m: add + m.group(0), s, count=1, flags=re.I)
    else: s += add
    print("license.html: font licences added (%d)" % len(blocks))
for marker in ("ITF Free Font License", "SIL OPEN FONT LICENSE"):
    assert marker.lower() in s.lower(), marker
open(page, 'w', encoding='utf-8').write(s)
EOF
[ $? -eq 0 ] || fail "license page"
# No page of the installer may still say FORMA or Resonance Audio (the font licence's "PERFORMANCE" is no match).
for n in welcome conclusion license; do
  if grep -wq FORMA "$W/res/$n.html"; then grep -wn FORMA "$W/res/$n.html" | head -3; fail "$n.html names FORMA"; fi
done
if grep -q 'Resonance Audio' "$W/res/"*.html; then fail "a page names Resonance Audio"; fi
cp "$W/res/welcome.html" "$LOG/welcome.html"
echo "::endgroup::"

echo "::group::Distribution"
D="$W/distribution.xml"
{
  echo '<?xml version="1.0" encoding="utf-8"?>'
  echo '<installer-gui-script minSpecVersion="2">'
  echo '  <title>Installa ZOKKU</title>'
  echo '  <welcome file="welcome.html" mime-type="text/html"/>'
  echo '  <license file="license.html" mime-type="text/html"/>'
  echo '  <conclusion file="conclusion.html" mime-type="text/html"/>'
  echo '  <background file="background.png" mime-type="image/png" alignment="bottomleft" scaling="proportional"/>'
  echo '  <background-darkAqua file="background-dark.png" mime-type="image/png" alignment="bottomleft" scaling="proportional"/>'
  echo '  <options customize="allow" require-scripts="false" hostArchitectures="arm64,x86_64"/>'
  echo '  <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>'
  echo '  <volume-check><allowed-os-versions><os-version min="11.0"/></allowed-os-versions></volume-check>'
  echo '  <choices-outline>'
  while IFS='|' read -r P NAME VER DESC KIND AU; do p=$(echo "$P" | tr A-Z a-z)
    echo "    <line choice=\"$p\">"
    while IFS='|' read -r F EXT FNAME DEST; do echo "      <line choice=\"$p.$F\"/>"; done <<< "$FORMATS"
    echo '    </line>'
  done <<< "$PRODUCTS"
  echo '  </choices-outline>'
  while IFS='|' read -r P NAME VER DESC KIND AU; do p=$(echo "$P" | tr A-Z a-z)
    echo "  <choice id=\"$p\" title=\"$NAME $VER\" description=\"$DESC ($KIND; VST3, AU e CLAP)\" start_selected=\"true\"/>"
    while IFS='|' read -r F EXT FNAME DEST; do
      echo "  <choice id=\"$p.$F\" title=\"$FNAME\" description=\"$NAME $VER in formato $FNAME, in $DEST\" start_selected=\"true\">"
      echo "    <pkg-ref id=\"com.zokku.$p.$F\"/>"
      echo '  </choice>'
      echo "  <pkg-ref id=\"com.zokku.$p.$F\" version=\"$VER\" onConclusion=\"none\">com.zokku.$p.$F.pkg</pkg-ref>"
    done <<< "$FORMATS"
  done <<< "$PRODUCTS"
  echo '</installer-gui-script>'
} > "$D"
cp "$D" "$LOG/distribution.xml"
xmllint --noout "$D" && echo "distribution.xml: well formed" || fail "distribution.xml"
echo "::endgroup::"

echo "::group::productbuild"
PKG="$W/dmg/$PKG_NAME"
NPROD=$(echo "$PRODUCTS" | grep -c .); NWANT=$((NPROD * 3))
if productbuild --distribution "$D" --resources "$W/res" --package-path "$W/pkgs" "$PKG" > "$LOG/productbuild.log" 2>&1; then
  echo "built $PKG_NAME ($(du -h "$PKG" | cut -f1))"; else cat "$LOG/productbuild.log"; fail "productbuild"; fi
pkgutil --expand "$PKG" "$W/expanded" && ls "$W/expanded" | tee "$LOG/pkg-contents.txt"
n=$(ls -d "$W/expanded"/com.zokku.*.pkg 2>/dev/null | wc -l | tr -d ' ')
[ "$n" = "$NWANT" ] || fail "product archive holds $n component packages, want $NWANT"
ns=$(find "$W/expanded" -path '*/Scripts*' -name postinstall 2>/dev/null | wc -l | tr -d ' ')
echo "component packages with the postinstall: $ns of $n"
pkgutil --check-signature "$PKG" > "$LOG/pkg-signature.txt" 2>&1; cat "$LOG/pkg-signature.txt"
spctl --assess --type install -vv "$PKG" > "$LOG/gatekeeper.txt" 2>&1; echo "Gatekeeper on the pkg (unsigned, expected rejected):"; cat "$LOG/gatekeeper.txt"
installer -showChoicesXML -pkg "$PKG" -target / > "$LOG/choices.xml" 2>&1
echo "choices selected by default: $(grep -A1 '<key>choiceIsSelected</key>' "$LOG/choices.xml" | grep -c '<integer>1</integer>') of $(grep -c '<key>choiceIsSelected</key>' "$LOG/choices.xml")"
echo "::endgroup::"

# MAC3: one pkg per product for ZOKKU Hub's catalogue (macos-universal releases): the same three component packages
# (with the same postinstall), no customisation, nothing else. The hub installs it with /usr/sbin/installer as root.
echo "::group::Product pkgs (hub catalogue)"
mkdir -p "$OUT/pkgs"; : > "$OUT/pkgs/SHA256SUMS.txt"
while IFS='|' read -r P NAME VER DESC KIND AU; do
  p=$(echo "$P" | tr A-Z a-z); d1="$W/dist-$p.xml"
  {
    echo '<?xml version="1.0" encoding="utf-8"?>'
    echo '<installer-gui-script minSpecVersion="2">'
    echo "  <title>ZOKKU $NAME $VER</title>"
    echo '  <options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"/>'
    echo '  <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>'
    echo '  <volume-check><allowed-os-versions><os-version min="11.0"/></allowed-os-versions></volume-check>'
    echo "  <choices-outline><line choice=\"$p\"/></choices-outline>"
    echo "  <choice id=\"$p\" title=\"$NAME $VER\">"
    while IFS='|' read -r F EXT FNAME DEST; do echo "    <pkg-ref id=\"com.zokku.$p.$F\"/>"; done <<< "$FORMATS"
    echo '  </choice>'
    while IFS='|' read -r F EXT FNAME DEST; do echo "  <pkg-ref id=\"com.zokku.$p.$F\" version=\"$VER\" onConclusion=\"none\">com.zokku.$p.$F.pkg</pkg-ref>"; done <<< "$FORMATS"
    echo '</installer-gui-script>'
  } > "$d1"
  f="ZOKKU-$NAME-$VER-macOS.pkg"
  if productbuild --distribution "$d1" --package-path "$W/pkgs" "$OUT/pkgs/$f" >> "$LOG/productbuild-products.log" 2>&1; then
    (cd "$OUT/pkgs" && shasum -a 256 "$f" >> SHA256SUMS.txt)
    echo "$f  $(stat -f %z "$OUT/pkgs/$f") bytes"
  else tail -5 "$LOG/productbuild-products.log"; fail "productbuild $f"; fi
done <<< "$PRODUCTS"
echo "::endgroup::"

# The upgrade a tester makes. With PREV: the FORMA trial pkg of 18 Oct installed first (RESONANCE, LOADLINE, ORIGIN,
# GRAFT and VELA in /Library, receipts com.forma.*), plus a copy of two of its bundles in the user's folder (plan B).
# Always: old-name copies (same id) of IKIPUMP in /Library, and a decoy CUTLINE.vst3 with another id that must stay.
echo "::group::Before: older installs on the runner"
echo "console user: $(stat -f %Su /dev/console 2>/dev/null) (runner user: $(id -un))"
UHOME="$HOME"
if [ -n "$PREV" ]; then
  old=$(find "$PREV" -name 'FORMA-Prova-*.dmg' | head -1)
  if [ -n "$old" ]; then
    M0="$W/mnt-old"; mkdir -p "$M0"
    if hdiutil attach -nobrowse -readonly -mountpoint "$M0" "$old" > /dev/null; then
      if sudo installer -pkg "$M0/Installa FORMA.pkg" -target / > "$LOG/install-forma.log" 2>&1; then echo "FORMA trial pkg ($(basename "$old")) installed"
      else tail -10 "$LOG/install-forma.log"; fail "installing the FORMA trial pkg"; fi
      hdiutil detach "$M0" > /dev/null
    else fail "attach $old"; fi
    for s in "VST3/VELA.vst3" "CLAP/RESONANCE.clap"; do
      mkdir -p "$UHOME/Library/Audio/Plug-Ins/$(dirname "$s")"
      ditto "/Library/Audio/Plug-Ins/$s" "$UHOME/Library/Audio/Plug-Ins/$s" && echo "plan-B copy: ~/Library/Audio/Plug-Ins/$s"
    done
  else echo "::warning title=package::no FORMA-Prova-*.dmg in $PREV: upgrade from FORMA not tested"; fi
fi
for f in vst3 component clap; do
  case $f in vst3) d=VST3;; component) d=Components;; clap) d=CLAP;; esac
  sudo ditto "$W/unz/ZOKKU-IKIPUMP-macOS/IKIPUMP.$f" "/Library/Audio/Plug-Ins/$d/PULSE.$f" && echo "old-name copy: /Library/Audio/Plug-Ins/$d/PULSE.$f"
done
sudo mkdir -p "/Library/Audio/Plug-Ins/VST3/CUTLINE.vst3/Contents"
sudo /usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string com.example.not-zokku' "/Library/Audio/Plug-Ins/VST3/CUTLINE.vst3/Contents/Info.plist" > /dev/null
echo "decoy: /Library/Audio/Plug-Ins/VST3/CUTLINE.vst3 (id com.example.not-zokku)"
for d in /Library/Audio/Plug-Ins/Components /Library/Audio/Plug-Ins/VST3 /Library/Audio/Plug-Ins/CLAP "$UHOME/Library/Audio/Plug-Ins/VST3" "$UHOME/Library/Audio/Plug-Ins/CLAP"; do
  for b in "$d"/*; do [ -e "$b" ] && echo "$b  $(version_of "$b")  $(id_of "$b")"; done
done | tee "$LOG/before.txt"
pkgutil --pkgs | grep -E '^com\.(forma|zokku)\.' | sort | tee "$LOG/receipts-before.txt"
echo "::endgroup::"

echo "::group::Install on the runner"
if sudo installer -pkg "$PKG" -target / -verboseR > "$LOG/install.log" 2>&1; then echo "installer: success"; else tail -20 "$LOG/install.log"; fail "installer"; fi
sudo cp /var/log/install.log "$LOG/system-install.log" 2>/dev/null; sudo chmod 644 "$LOG/system-install.log" 2>/dev/null
grep -h 'zokku-postinstall' "$LOG/system-install.log" "$LOG/install.log" 2>/dev/null | sed -E 's/^.*(zokku-postinstall)/\1/' | sort -u | tee "$LOG/postinstall.txt"
sleep 5
: > "$LOG/installed.txt"
while IFS='|' read -r P NAME VER DESC KIND AU; do
  while IFS='|' read -r F EXT FNAME DEST; do
    b="$DEST/$NAME.$EXT"
    if [ -d "$b" ]; then
      v=$(version_of "$b")
      own=$(stat -f '%Su:%Sg' "$b")
      codesign --verify --deep --strict "$b" 2>/dev/null && s=ok || { s=INVALID; fail "installed $b signature"; }
      xattr -r "$b" 2>/dev/null | grep -q quarantine && q=QUARANTINED || q="no quarantine"
      echo "$b  $v  $own  signature $s  $q" | tee -a "$LOG/installed.txt"
      [ "$v" = "$VER" ] || fail "installed $b version $v, want $VER"
    else fail "not installed: $b"; fi
    # The same plug-in under the folder name (the FORMA name) must be gone when the name changed.
    # (MAC3: a bundle with the old name and another id, the decoy, must stay: only the same id counts)
    if [ "$NAME" != "$P" ] && [ -e "$DEST/$P.$EXT" ] && [ "$(id_of "$DEST/$P.$EXT")" = "$(id_of "$b")" ]; then fail "old-name bundle still installed: $DEST/$P.$EXT"; fi
  done <<< "$FORMATS"
done <<< "$PRODUCTS"
pkgutil --pkgs | grep -E '^com\.(forma|zokku)\.' | sort > "$LOG/receipts.txt"
echo "receipts com.zokku.*: $(grep -c '^com\.zokku\.' "$LOG/receipts.txt"), com.forma.* left: $(grep -c '^com\.forma\.' "$LOG/receipts.txt")"
[ "$(grep -c '^com\.zokku\.' "$LOG/receipts.txt")" = "$NWANT" ] || fail "zokku receipts"
if grep -q '^com\.forma\.' "$LOG/receipts.txt"; then fail "FORMA receipts not forgotten"; fi
echo "::endgroup::"

echo "::group::Product pkgs installed one by one (as the hub does)"
while IFS='|' read -r P NAME VER DESC KIND AU; do
  f="$OUT/pkgs/ZOKKU-$NAME-$VER-macOS.pkg"; [ -f "$f" ] || continue
  if sudo installer -pkg "$f" -target / > "$LOG/install-$NAME.log" 2>&1; then
    v=$(version_of "/Library/Audio/Plug-Ins/VST3/$NAME.vst3"); echo "$NAME pkg: installed, VST3 $v"
    [ "$v" = "$VER" ] || fail "$NAME pkg: VST3 version $v"
  else tail -5 "$LOG/install-$NAME.log"; fail "installer $NAME pkg"; fi
done <<< "$PRODUCTS"
echo "::endgroup::"

echo "::group::Old bundles moved away"
if [ -d "/Library/Audio/Plug-Ins/VST3/CUTLINE.vst3" ]; then echo "decoy with another id left in place: ok"; else fail "decoy with another id was touched"; fi
sudo rm -rf "/Library/Audio/Plug-Ins/VST3/CUTLINE.vst3"
for d in "$UHOME/Library/Audio/Plug-Ins/VST3" "$UHOME/Library/Audio/Plug-Ins/CLAP"; do
  for b in "$d"/*; do if [ -e "$b" ]; then fail "still in the user's folder: $b"; fi; done
done
find "$BACKUP_DIR" -maxdepth 8 \( -name '*.vst3' -o -name '*.component' -o -name '*.clap' \) -prune 2>/dev/null | sed "s#^$BACKUP_DIR/##" | sort | tee "$LOG/moved.txt"
echo "moved bundles: $(grep -c . "$LOG/moved.txt")"
if [ -n "$PREV" ]; then
  for want in RESONANCE.component RESONANCE.vst3 RESONANCE.clap LOADLINE.vst3 ORIGIN.component GRAFT.clap VELA.vst3; do
    grep -q "/$want\$" "$LOG/moved.txt" || fail "not moved: $want"
  done
fi
for want in PULSE.vst3 PULSE.component PULSE.clap; do grep -q "/$want\$" "$LOG/moved.txt" || fail "not moved: $want"; done
echo "::endgroup::"

echo "::group::auval (installed in /Library)"
auval -a 2>/dev/null | grep "Rsna" | tee "$LOG/auval-list.txt"
while IFS='|' read -r P NAME VER DESC KIND AU; do
  set -- $AU Rsna
  c=$(grep -c " $2 Rsna" "$LOG/auval-list.txt")
  [ "$c" = 1 ] || fail "auval lists $AU Rsna $c times (want once)"
  if auval -v "$1" "$2" "$3" > "$LOG/auval-$2.log" 2>&1 && grep -q "AU VALIDATION SUCCEEDED" "$LOG/auval-$2.log"; then echo "auval -v $1 $2 $3 ($NAME): PASS"
  else tail -30 "$LOG/auval-$2.log"; fail "auval $AU ($NAME)"; fi
done <<< "$PRODUCTS"
if grep "Rsna" "$LOG/auval-list.txt" | grep -v "ZOKKU"; then fail "an Audio Unit without the ZOKKU producer"; fi
echo "::endgroup::"

echo "::group::dmg"
cp "$RES/Leggimi.txt" "$W/dmg/Leggimi - Read me.txt" || fail "missing pkg/zokku/Leggimi.txt"
# MAC3: ZOKKU Hub.app (from the hub job) beside the installer, with a link to /Applications to drag it there
hz=$(find "$IN" -name "ZOKKU-Hub-macOS.zip" | head -1)
if [ -n "$hz" ]; then
  ditto -x -k "$hz" "$W/dmg" && ln -s /Applications "$W/dmg/Applications"
  codesign --verify --deep --strict "$W/dmg/ZOKKU Hub.app" && echo "ZOKKU Hub.app $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$W/dmg/ZOKKU Hub.app/Contents/Info.plist"): signature verified" || fail "hub app signature"
  HV=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$W/dmg/ZOKKU Hub.app/Contents/Info.plist")   # REL: the name follows the app
  (cd "$W/dmg" && ditto -c -k --sequesterRsrc --keepParent "ZOKKU Hub.app" "$OUT/ZOKKU-Hub-$HV-macOS.zip") && (cd "$OUT" && shasum -a 256 "ZOKKU-Hub-$HV-macOS.zip" > "ZOKKU-Hub-$HV-macOS.zip.sha256")
else fail "missing ZOKKU-Hub-macOS.zip (hub job)"; fi
# The PDF guide of 18 Oct still names FORMA: it goes in the dmg only once its ZOKKU version is in pkg/zokku.
if [ -f "$RES/$GUIDE_PDF" ]; then cp "$RES/$GUIDE_PDF" "$W/dmg/"; echo "guide PDF included"
else echo "::warning title=package::$GUIDE_PDF (ZOKKU) not in pkg/zokku: the dmg holds the installer and Leggimi.txt"; fi
rm -f "$OUT/$DMG_NAME"
if hdiutil create -volname "ZOKKU Beta" -srcfolder "$W/dmg" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$OUT/$DMG_NAME" > "$LOG/hdiutil.log" 2>&1; then
  echo "dmg: $(du -h "$OUT/$DMG_NAME" | cut -f1)"; else cat "$LOG/hdiutil.log"; fail "hdiutil create"; fi
hdiutil verify "$OUT/$DMG_NAME" >> "$LOG/hdiutil.log" 2>&1 && echo "hdiutil verify: ok" || fail "hdiutil verify"
hdiutil imageinfo "$OUT/$DMG_NAME" | grep -E "Format:|Format Description" | head -2
M="$W/mnt"; mkdir -p "$M"
if hdiutil attach -nobrowse -readonly -mountpoint "$M" "$OUT/$DMG_NAME" > /dev/null; then
  ls -la "$M" | tee "$LOG/dmg-contents.txt"
  [ -f "$M/$PKG_NAME" ] || fail "dmg without the pkg"
  cmp -s "$M/$PKG_NAME" "$PKG" && echo "pkg in the dmg identical to the one tested" || fail "pkg in dmg differs"
  hdiutil detach "$M" > /dev/null
else fail "hdiutil attach"; fi
(cd "$OUT" && shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256" && cat "$DMG_NAME.sha256")
echo "::endgroup::"

if [ ${#FAILED[@]} -gt 0 ]; then echo "FAILED: ${FAILED[*]}"; exit 1; fi
echo "package: all checks passed"
