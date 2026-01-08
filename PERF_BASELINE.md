# Performance Baseline

Date: Wed Jan 7 22:01:02 EST 2026  
Commit: f69be4b45af1e6d8b18a239d69d1c20d59199bb5  
Zig: 0.15.2  

Run via `nix develop -c` in repo root.

Command:
```
zig build -Doptimize=ReleaseFast bench -- --input-size 1048576 --trials 10 --noise-pcts 0,1,2.5,5,10 --shape random --format text
```

Output:
```
raw throughput (noise_pct=0)
encode_mbps=103.28 decode_mbps=505.51 total_mbps=85.76

resilience report (shape=random)
noise_pct=0.00 success_rate=0.0000 encode_mbps=103.28 decode_mbps=505.51 total_mbps=85.76
noise_pct=1.00 success_rate=0.0000 encode_mbps=104.59 decode_mbps=561.10 total_mbps=88.15
noise_pct=2.50 success_rate=0.0000 encode_mbps=104.28 decode_mbps=543.66 total_mbps=87.50
noise_pct=5.00 success_rate=0.0000 encode_mbps=104.19 decode_mbps=547.83 total_mbps=87.54
noise_pct=10.00 success_rate=0.0000 encode_mbps=104.91 decode_mbps=545.32 total_mbps=87.99
noise_pct,shape,trials,successes,success_rate,avg_encode_mbps,avg_decode_mbps,avg_total_mbps
0.0000,random,5,0,0.000000,103.2823,505.5101,85.7604
1.0000,random,5,0,0.000000,104.5850,561.1043,88.1539
2.5000,random,5,0,0.000000,104.2775,543.6555,87.4952
5.0000,random,5,0,0.000000,104.1927,547.8251,87.5427
10.0000,random,5,0,0.000000,104.9142,545.3157,87.9863
{"shape":"random","raw_throughput":{"avg_encode_mbps":103.2823,"avg_decode_mbps":505.5101,"avg_total_mbps":85.7604},"rows":[{"noise_pct":0.000000,"trials":5,"successes":0,"success_rate":0.000000,"avg_encode_mbps":103.2823,"avg_decode_mbps":505.5101,"avg_total_mbps":85.7604},{"noise_pct":1.000000,"trials":5,"successes":0,"success_rate":0.000000,"avg_encode_mbps":104.5850,"avg_decode_mbps":561.1043,"avg_total_mbps":88.1539},{"noise_pct":2.500000,"trials":5,"successes":0,"success_rate":0.000000,"avg_encode_mbps":104.2775,"avg_decode_mbps":543.6555,"avg_total_mbps":87.4952},{"noise_pct":5.000000,"trials":5,"successes":0,"success_rate":0.000000,"avg_encode_mbps":104.1927,"avg_decode_mbps":547.8251,"avg_total_mbps":87.5427},{"noise_pct":10.000000,"trials":5,"successes":0,"success_rate":0.000000,"avg_encode_mbps":104.9142,"avg_decode_mbps":545.3157,"avg_total_mbps":87.9863}]}
```

Notes:
- Bench step currently ignores CLI args forwarded after `--`, so the run used default `trials=5` and default output formats (text+csv+json) despite the command specifying otherwise.

---

Date: Thu Jan  8 00:50:57 EST 2026  
Commit: 517ddc684c7055ac82cdd21607a555080e83adb0  
Zig: 0.15.2  

Run via `nix develop -c` in repo root.

Command:
```
zig build -Doptimize=ReleaseFast bench -- --input-size 1048576 --trials 10 --overhead-pct 20 --ber-list 1e-9,1e-7,1e-6,1e-5,1e-4 --format text
```

Output:
```
resilience report (shape=ber)
ber=1.000e-9 success_rate=1.0000 encode_mbps=81.49 decode_mbps=378.93 total_mbps=67.07
ber=1.000e-7 success_rate=1.0000 encode_mbps=96.66 decode_mbps=333.23 total_mbps=74.93
ber=1.000e-6 success_rate=1.0000 encode_mbps=95.75 decode_mbps=154.35 total_mbps=59.09
ber=1.000e-5 success_rate=0.5000 encode_mbps=94.32 decode_mbps=114.45 total_mbps=51.71
ber=1.000e-4 success_rate=0.0000 encode_mbps=96.74 decode_mbps=970.69 total_mbps=87.97
```
