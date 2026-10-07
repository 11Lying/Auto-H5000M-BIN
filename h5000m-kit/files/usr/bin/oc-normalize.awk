#!/usr/bin/awk -f
# Normalize a proxies block: consistent 2-space base indentation for list items,
# preserving relative field indentation. Handles flow and block style.
BEGIN { inblk = 0; curbase = 2 }
{
  line = $0
  if (line ~ /^proxies:[ \t]*$/) { print "proxies:"; inblk = 0; next }
  if (line ~ /^[ \t]*-[ \t]/ || line ~ /^[ \t]*-$/) {
    match(line, /^[ \t]*/); base = RLENGTH
    rel = substr(line, base + 1)
    print "  " rel
    curbase = base; inblk = 1; next
  }
  if (line ~ /^[ \t]*$/) { next }
  if (inblk) {
    match(line, /^[ \t]*/); lead = RLENGTH
    reln = lead - curbase
    if (reln < 0) reln = 0
    pad = ""
    for (i = 0; i < reln; i++) pad = pad " "
    print "  " pad substr(line, lead + 1)
  } else {
    print line
  }
}