import argparse, subprocess, sys, time
SCENARIOS=[f'E{i}' for i in range(1,13)]
CONDITIONS=['safe','failure','governed']
def main():
 ap=argparse.ArgumentParser(); ap.add_argument('--repetitions',type=int,default=5); args=ap.parse_args()
 for sid in SCENARIOS:
  for cond in CONDITIONS:
   for r in range(args.repetitions):
    print(f'=== {sid} {cond} repetition {r+1}/{args.repetitions} ===')
    p=subprocess.run([sys.executable,'experiments/runner.py','--scenario',sid,'--condition',cond],text=True)
    if p.returncode!=0: print('FAILED; continuing so failures are explicit in the run log')
    time.sleep(5)
if __name__=='__main__': main()
