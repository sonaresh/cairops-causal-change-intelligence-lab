$env:CAIROPS_LAB_ACK='YES'
python .\experiments\runner.py --scenario E1 --condition safe
python .\experiments\runner.py --scenario E1 --condition failure
python .\experiments\runner.py --scenario E1 --condition governed
