#!/usr/bin/awk -f
# Convert proxy URI list (vless/tuic/hysteria2/anytls) to Mihomo YAML proxies block.
# Reads one URI per line on stdin, writes YAML to stdout.
function hex2int(h,   i,c,v,p){ v=0; for(i=1;i<=length(h);i++){ c=tolower(substr(h,i,1)); p=index("0123456789abcdef",c)-1; if(p<0)p=0; v=v*16+p } return v }
function urldec(s,   out,i,c){
  out=""
  for(i=1;i<=length(s);i++){
    c=substr(s,i,1)
    if(c=="%" && i+2<=length(s)){ out=out sprintf("%c", hex2int(substr(s,i+1,2))); i+=2 }
    else out=out c
  }
  return out
}
function qget(q,k,   n,a,i,p){
  n=split(q,a,"&")
  for(i=1;i<=n;i++){ p=index(a[i],"="); if(p>0 && substr(a[i],1,p-1)==k) return urldec(substr(a[i],p+1)) }
  return ""
}
function yq(v){ gsub(/\\/,"\\\\",v); gsub(/"/,"\\\"",v); return v }
BEGIN{ print "proxies:" }
/^[ \t]*$/ { next }
{
  line=$0
  sub(/\r$/,"",line)
  # scheme
  p=index(line,"://"); if(p==0) next
  scheme=tolower(substr(line,1,p-1))
  rest=substr(line,p+3)
  # name after #
  name=""; q=""
  h=index(rest,"#")
  if(h>0){ name=urldec(substr(rest,h+1)); rest=substr(rest,1,h-1) }
  # query
  qq=index(rest,"?")
  if(qq>0){ q=substr(rest,qq+1); rest=substr(rest,1,qq-1) }
  # strip trailing slash from rest
  sub(/\/$/,"",rest)
  # cred
  cred=""
  at=index(rest,"@")
  if(at>0){ cred=substr(rest,1,at-1); hostport=substr(rest,at+1) } else { hostport=rest }
  # host:port (handle [v6])
  if(substr(hostport,1,1)=="["){
    rb=index(hostport,"]"); server=substr(hostport,2,rb-2); port=substr(hostport,rb+2)
  } else {
    cp=hostport; cc=index(cp,":"); server=substr(cp,1,cc-1); port=substr(cp,cc+1)
  }
  if(server==""||port=="") next
  if(scheme!="vless"&&scheme!="tuic"&&scheme!="hysteria2"&&scheme!="anytls") next
  # skip non-node names
  if(!keepinfo && name ~ /剩余|流量|到期|套餐|官网|客服|公告|群组|频道|请勿滥用|@honghong|官方网站|订阅/) next
  # emit
  printf "  - name: \"%s\"\n", yq(name)
  if(scheme=="hysteria2"){
    printf "    type: hysteria2\n    server: \"%s\"\n    port: %d\n    password: \"%s\"\n", server, port, cred
    sn=qget(q,"sni"); if(sn!="") printf "    sni: \"%s\"\n", sn
    if(qget(q,"insecure")=="1") printf "    skip-cert-verify: true\n"
    ob=qget(q,"obfs"); if(ob!="") printf "    obfs: \"%s\"\n", ob
    op=qget(q,"obfs-password"); if(op!="") printf "    obfs-password: \"%s\"\n", yq(op)
  } else if(scheme=="tuic"){
    uuid=cred; pw=""
    cc=index(cred,":"); if(cc>0){ uuid=substr(cred,1,cc-1); pw=substr(cred,cc+1) }
    printf "    type: tuic\n    server: \"%s\"\n    port: %d\n    uuid: \"%s\"\n    password: \"%s\"\n", server, port, uuid, pw
    sn=qget(q,"sni"); if(sn!="") printf "    sni: \"%s\"\n", sn
    al=qget(q,"alpn"); if(al!="") printf "    alpn:\n      - \"%s\"\n", al
    cg=qget(q,"congestion_control"); printf "    congestion-controller: \"%s\"\n", (cg==""?"bbr":cg)
    ur=qget(q,"udp_relay_mode"); if(ur!="") printf "    udp-relay-mode: \"%s\"\n", ur
    if(qget(q,"disable_sni")=="1") printf "    disable-sni: true\n"
    if(qget(q,"allow_insecure")=="1") printf "    skip-cert-verify: true\n"
  } else if(scheme=="vless"){
    uuid=cred; cc=index(uuid,":"); if(cc>0) uuid=substr(uuid,1,cc-1)
    printf "    type: vless\n    server: \"%s\"\n    port: %d\n    uuid: \"%s\"\n", server, port, uuid
    sec=qget(q,"security")
    if(sec=="reality"||qget(q,"tls")!=""||qget(q,"sni")!=""){
      printf "    tls: true\n"
      sn=qget(q,"sni"); if(sn!="") printf "    servername: \"%s\"\n", sn
      fl=qget(q,"flow"); if(fl!="") printf "    flow: \"%s\"\n", fl
      pbk=qget(q,"pbk")
      if(pbk!=""){ printf "    reality-opts:\n      public-key: \"%s\"\n", pbk; sid=qget(q,"sid"); if(sid!="") printf "      short-id: \"%s\"\n", sid }
      fp=qget(q,"fp"); if(pbk!=""||fp!="") printf "    client-fingerprint: \"%s\"\n", (fp==""?"ios":fp)
    }
    nt=qget(q,"type")
    if(nt=="ws"||qget(q,"path")!=""){
      printf "    network: ws\n    ws-opts:\n"
      pa=qget(q,"path"); if(pa!="") printf "      path: \"%s\"\n", pa
      ho=qget(q,"host"); if(ho!=""){ printf "      headers:\n        Host: \"%s\"\n", ho }
    }
  } else if(scheme=="anytls"){
    printf "    type: anytls\n    server: \"%s\"\n    port: %d\n    password: \"%s\"\n", server, port, cred
    sn=qget(q,"sni"); if(sn!="") printf "    sni: \"%s\"\n", sn
    fp=qget(q,"fp"); printf "    client-fingerprint: \"%s\"\n", (fp==""?"chrome":fp)
    if(qget(q,"insecure")=="1") printf "    skip-cert-verify: true\n"
  } else {
    # unknown scheme: skip (do not emit partial)
  }
}