import math
WEIGHTS={'H':1.20,'D':1.00,'P':1.50,'B':1.10,'U':0.85,'V':1.00,'R':0.80}
def clamp(x): return max(0.0,min(1.0,float(x)))
def sigmoid(x): return 1/(1+math.exp(-x))
def ciir(f):
    z=(WEIGHTS['H']*clamp(f['H']) + WEIGHTS['D']*clamp(f['D']) + WEIGHTS['P']*clamp(f['P']) + WEIGHTS['B']*clamp(f['B']) + WEIGHTS['U']*clamp(f['U']) - WEIGHTS['V']*clamp(f['V']) - WEIGHTS['R']*clamp(f['R']) - 1.5)
    return clamp(sigmoid(z))
def band(x):
    return 'low' if x<0.35 else ('medium' if x<0.65 else ('high' if x<0.85 else 'critical'))
