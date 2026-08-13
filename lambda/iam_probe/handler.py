import os, time, boto3, json
s3=boto3.client('s3')
def handler(event, context):
    key=f"iam-probe/{event.get('run_id','manual')}-{int(time.time())}.json"
    body=json.dumps({'ok':True,'run_id':event.get('run_id'),'ts':time.time()}).encode()
    s3.put_object(Bucket=os.environ['EVIDENCE_BUCKET'],Key=key,Body=body,ContentType='application/json')
    return {'ok':True,'key':key}
