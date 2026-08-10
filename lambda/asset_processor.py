import json

def handler(event, context):
    for record in event.get("Records", []):
        bucket = record["s3"]["bucket"]["name"]
        key = record["s3"]["object"]["key"]
        print(f"Image received: {key}")
    return {
        "statusCode": 200,
        "body": json.dumps("Processed S3 event")
    }
