import os
import boto3

def lambda_handler(event, context):
    ec2 = boto3.client('ec2')

    active_id = os.environ['ACTIVE_INSTANCE_ID']
    passive_id = os.environ['PASSIVE_INSTANCE_ID']
    allocation_id = os.environ['EIP_ALLOCATION_ID']

    try:
        print(f"Checking status of instance {active_id}")
        response = ec2.describe_instance_status(
            InstanceIds=[active_id],
            IncludeAllInstances=True
        )
        instance_state = response['InstanceStatuses'][0]['InstanceState']['Name']
        print(f"Active instance state: {instance_state}")

        if instance_state != 'running':
            print("Active instance is down. Switching EIP to passive instance...")

            addresses = ec2.describe_addresses(AllocationIds=[allocation_id])
            association_id = addresses['Addresses'][0].get('AssociationId')

            if association_id:
                ec2.disassociate_address(AssociationId=association_id)
                print("Disassociated EIP")

            ec2.associate_address(InstanceId=passive_id, AllocationId=allocation_id)
            print(f"EIP associated with passive instance {passive_id}")
        else:
            print("Active instance is running. No action needed.")

    except Exception as e:
        print(f"Failover script failed: {e}")