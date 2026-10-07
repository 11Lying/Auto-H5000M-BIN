#!/bin/sh
# Build a pool of up to POOL_SIZE HEALTHY candidate nodes for the auto-select group.
#
# Strategy (low-resource, never a full scan):
#   1. reuse previously-verified healthy nodes (cache) and re-verify them
#   2. if short, randomly sample small batches and health-check them via Mihomo API
#   3. paid nodes sampled first (far more reliable), free nodes only as fallback
#   4. keep only nodes that pass a REAL proxy health test; stop at POOL_SIZE
#
# Modes: (default) rebuild | --check: verify pool, act only if too unhealthy
PROV="/etc/openclash/proxy_provider"
OUT="$PROV/candidates.yml"
CACHE="/etc/openclash/candidate_cache"
LOG="/tmp/oc-candidate.log"
API="http://127.0.0.1:9090"
SEC="$(uci get openclash.config.dashboard_password 2>/dev/null)"
[ -z "$SEC" ] && SEC="KNPeboRn"
POOL_SIZE=20
BATCH=8            # concurrent health checks
HEALTH_TMO=3000    # ms per-node health timeout
MAX_CHECK=60       # hard cap on health checks per run (<< total => never full scan)
MIN_OK=12          # --check: if >= this many healthy, do nothing
MODE="rebuild"
[ "$1" = "--check" ] && MODE="check"

log(){ echo "$(date '+%H:%M:%S') $*" >> "$LOG"; }
uniq(){ awk '!s[$0]++'; }

TMPD="$(mktemp -d /tmp/occ.XXXXXX)"
trap 'rm -rf "$TMPD"' EXIT
RES="$TMPD/res"; : > "$RES"

# ---------- 1. index all nodes: name <TAB> blockfile (paid first, then free) ----------
NAMEAWK='
function unq(v,   q1,q2){ q1=sprintf("%c",39); q2=sprintf("%c",34); gsub(/^[ \t]+|[ \t]+$/,"",v); gsub("^[" q1 q2 "]+","",v); gsub("[" q1 q2 "]+$","",v); return v }
function namef(s,   p,i,c,out,n){ p=index(s,"name:"); if(p==0) return ""; s=substr(s,p+5); sub(/^[ \t]+/,"",s); n=length(s); out=""; for(i=1;i<=n;i++){ c=substr(s,i,1); if(c==","||c=="}") break; out=out c } return unq(out) }
function emit(   fn){ if(cur=="") return; fn=sprintf("%s/b%d.txt",OUTDIR,idx); printf "%s",cur > fn; close(fn); printf "%s\t%s\n", cur_name, fn; cur="" }
/^[ \t]*- name:/{ emit(); cur_name=$0; sub(/^[ \t]*- name:[ \t]*/,"",cur_name); cur_name=unq(cur_name); cur=$0 ORS; idx++; next }
/^[ \t]*-[ \t]*\{/{
  emit(); idx++; cur=""; cur_name=namef($0)
  fn=sprintf("%s/b%d.txt",OUTDIR,idx); print $0 > fn; close(fn)
  printf "%s\t%s\n", cur_name, fn; cur_name=""; next
}
{ if(cur!="") cur=cur $0 ORS }
END{ emit() }
'
awk -v OUTDIR="$TMPD" "$NAMEAWK" "$PROV/paidaer.yml" "$PROV/freesub.yml" | uniq > "$TMPD/index" 2>/dev/null

TOTAL=$(wc -l < "$TMPD/index")
[ "$TOTAL" -ge 1 ] || { echo "proxies:"; log "no nodes"; exit 0; }
PAID_N=$(grep -cE "^[ \t]*- (name:|\{)" "$PROV/paidaer.yml" 2>/dev/null)

block_of(){ awk -F'\t' -v n="$1" '$1==n{print $2; exit}' "$TMPD/index"; }

# ---------- 2. health check ----------
check_one(){
  enc=$(jq -rn --arg x "$1" '$x|@uri' 2>/dev/null)
  [ -z "$enc" ] && return 1
  r=$(curl -s -H "Authorization: Bearer $SEC" --max-time 8 \
      "$API/proxies/$enc/delay?url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204&timeout=$HEALTH_TMO" 2>/dev/null)
  case "$r" in *'"delay"'*) echo "$1" >> "$RES" ;; esac
}
check_file(){   # $1 = file of names
  f="$1"; i=0; n=$(wc -l < "$f")
  while [ "$i" -lt "$n" ]; do
     sed -n "$((i+1)),$((i+BATCH))p" "$f" > "$TMPD/batch"
     while IFS= read -r nm; do [ -n "$nm" ] && check_one "$nm" & done < "$TMPD/batch"
     wait
     i=$((i+BATCH))
  done
}
remove_selected(){  # $1=remain file ; $2=sample file
  awk 'NR==FNR{s[$0]=1;next} !($0 in s){print}' "$2" "$1" > "$1.n" && mv "$1.n" "$1"
}

# ---------- 3. cached healthy nodes ----------
: > "$TMPD/checked"
if [ -s "$CACHE" ]; then
   awk -F'\t' 'NR==FNR{c[$1]=1;next} ($1 in c){print $1}' "$CACHE" "$TMPD/index" > "$TMPD/cached"
else
   : > "$TMPD/cached"
fi

emit_out(){  # $1 = pool file -> candidates.yml
  echo "proxies:"
  while IFS= read -r nm; do b=$(block_of "$nm"); [ -n "$b" ] && cat "$b"; done < "$1"
}

if [ "$MODE" = "check" ] && [ -s "$TMPD/cached" ]; then
   : > "$RES"; check_file "$TMPD/cached"
   n=$(uniq < "$RES" | wc -l)
   [ "$n" -ge "$MIN_OK" ] && { log "check: $n healthy (>= $MIN_OK) -> no action"; exit 0; }
   log "check: only $n healthy -> rebuild"
fi

# ---------- 4. rebuild ----------
: > "$RES"
[ -s "$TMPD/cached" ] && { check_file "$TMPD/cached"; cat "$TMPD/cached" >> "$TMPD/checked"; }
uniq < "$RES" > "$TMPD/pool"

# split remaining into paid / free (paid first for efficiency)
head -n "$PAID_N" "$TMPD/index" | cut -f1 > "$TMPD/n_paid"
tail -n +"$((PAID_N+1))" "$TMPD/index" | cut -f1 > "$TMPD/n_free"
if [ -s "$TMPD/checked" ]; then
   awk 'NR==FNR{c[$0]=1;next} !($0 in c){print}' "$TMPD/checked" "$TMPD/n_paid" > "$TMPD/rem_paid"
   awk 'NR==FNR{c[$0]=1;next} !($0 in c){print}' "$TMPD/checked" "$TMPD/n_free" > "$TMPD/rem_free"
else
   cp "$TMPD/n_paid" "$TMPD/rem_paid"; cp "$TMPD/n_free" "$TMPD/rem_free"
fi

NC=$(wc -l < "$TMPD/pool")
while [ "$NC" -lt "$POOL_SIZE" ]; do
   TOT=$(wc -l < "$TMPD/checked")
   [ "$TOT" -ge "$MAX_CHECK" ] && break
   if [ -s "$TMPD/rem_paid" ]; then SRC="$TMPD/rem_paid"
   elif [ -s "$TMPD/rem_free" ]; then SRC="$TMPD/rem_free"
   else break; fi
   awk -v k="$BATCH" -v sd="$NC${RANDOM}$TOT" 'BEGIN{srand(sd+1)}
        {a[NR]=$0} END{ n=NR; if(k>n)k=n
          for(i=1;i<=n;i++){ j=int(rand()*n)+1; t=a[i];a[i]=a[j];a[j]=t }
          for(i=1;i<=k;i++) print a[i] }' "$SRC" > "$TMPD/sample"
   remove_selected "$SRC" "$TMPD/sample"
   : > "$RES"
   check_file "$TMPD/sample"
   cat "$TMPD/sample" >> "$TMPD/checked"
   cat "$RES" >> "$TMPD/pool"
   uniq < "$TMPD/pool" > "$TMPD/pool.u" && mv "$TMPD/pool.u" "$TMPD/pool"
   NC=$(wc -l < "$TMPD/pool")
done

[ "$NC" -gt "$POOL_SIZE" ] && { head -n "$POOL_SIZE" "$TMPD/pool" > "$TMPD/pool.t"; mv "$TMPD/pool.t" "$TMPD/pool"; NC=$POOL_SIZE; }

# ---------- 5. emit + cache ----------
emit_out "$TMPD/pool" > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
cp "$TMPD/pool" "$CACHE"
log "pool=$NC  checked=$(wc -l < "$TMPD/checked")/$TOTAL  paid_avail=$PAID_N  mode=$MODE"
exit 0