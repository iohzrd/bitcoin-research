"""Block sizes from the mainnet node, every STEP-th block (read-only getblockstats, 0.5 s apart)."""
import json, time, urllib.request, base64, sys
STEP = 1000  # 200 below height 345,000 in block_sizes_sampled.txt, 1000 above
cfg = json.load(open("/home/iohzrd/tn4/gateway.json"))["bitcoind"]
auth = base64.b64encode(f"{cfg['rpcuser']}:{cfg['rpcpassword']}".encode()).decode()
def rpc(method, *params):
    req = urllib.request.Request(cfg["rpcurl"], data=json.dumps({"jsonrpc": "1.0", "id": 0, "method": method, "params": list(params)}).encode(),
                                 headers={"Authorization": "Basic " + auth, "Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=60))["result"]
tip = rpc("getblockcount")
out = sys.argv[1]
done = {}
try:
    for line in open(out):
        h, size = map(int, line.split())
        done[h] = size
except FileNotFoundError:
    pass
with open(out, "a") as f:
    for h in range(0, tip + 1, STEP):
        if h in done:
            continue
        s = rpc("getblockstats", h, ["total_size"])
        f.write(f"{h} {s['total_size']}\n")
        f.flush()
        time.sleep(0.5)
print("tip", tip)
