#!/bin/bash
## This script start an amazon aws instance and ssh to the instance. when terminate the ssh connection, the instance is automatically stopped. Please NOTICE that, if you force terminate the ssh rather than logout, the instance will not be stopped, you have to stop it manualy. Please use "logout" in ssh and "quit" in sftp. If this script runs without arguement, it will default to start the upload machine. This script may ask for the key phrase.
#  VERSION 1.0
#  Liyuan ZHOU, NICTA CRL, 2014
#
# Usage: 
#	start_instance.sh [-t] [-n <instance-type>] [-s <instance-type>] [-i <instance-id>] [-k <key-pair>]
#	
#	-t: transfer data from given instance using sftp.
#	-n <instance-type>: new an instance with the given instance-type using our default system image.
#	-s <instance-type>: new a spot instance with the given instance-type using our default system image. Note that the bid price would be the highest in the past week in ap-southeast-2b.
#	-i <instance-id>: connect to given instance id.
#	-k <key-pair>: use costermize key pair.
#
#	instance-type:	t2.micro
#			t2.small
#			t2.medium
#			m3.medium
#			m3.large
#			m3.xlarge
#			m3.2xlarge
#			c3.large
#			c3.xlarge
#			c3.2xlarge
#			c3.4xlarge
#			c3.8xlarge
#			g2.2xlarge
#			r3.large
#			r3.xlarge
#			r3.2xlarge
#			r3.4xlarge	
#			r3.8xlarge	
#			i2.xlarge
#			i2.2xlarge
#			i2.4xlarge
#			i2.8xlarge
#			hs1.8xlarge
#
#	
# Example: 
#	./start_instance.sh -u
#		
#															
#***********************************************************************
# READING ARGUMENTS
#***********************************************************************
INSTANCE_ID=""
SFTP=0
SERVER_ADDRESS=''
# DL_v1.2 mount instance storage
SYSTEM_IMAGE=ami-893b4eb3
VOLUME_ID=""
SPOT_INSTANCE=0
NEW_INSTANCE=0
KEY=DL_gpu.pem


# enable the automatical complete for choice of instance types
source ./_instanceTypeComplete_
# import the spot instance price calculation function
source ./instancePrice



while getopts tn:s:i:k: option
do
	case "${option}"
	in
			
			t) SFTP=1;;
			n) NEW_INSTANCE=1; INSTANCE_TYPE=${OPTARG};;
			s) SPOT_INSTANCE=1; INSTANCE_TYPE=${OPTARG};;
			i) INSTANCE_ID=${OPTARG};;
			U) KEY=${OPTARG};;
			
	esac
done
#**************************************************************************
# New an instance if required
#**************************************************************************

if [ $NEW_INSTANCE -eq 1 ]
then
	echo "new an $INSTANCE_TYPE instance"
	# Catch the instance id after generating a new instance so that we can manage it later
	INSTANCE_ID=`aws ec2 run-instances --image-id $SYSTEM_IMAGE --count 1 --instance-type $INSTANCE_TYPE --key-name DL_gpu --security-groups DL_Experiment --block-device-mapping "[{\"DeviceName\": \"/dev/sdb\",\"VirtualName\":\"ephemeral0\"}]" --block-device-mapping "[{\"DeviceName\": \"/dev/sdc\",\"VirtualName\":\"ephemeral1\"}]"
| grep -m 1 -o "\bi-.\{8\}"`
	echo "Instance ID: $INSTANCE_ID"
fi

#**************************************************************************
# Request a spot instance
#**************************************************************************

if [ $SPOT_INSTANCE -eq 1 ]
then
	echo "new a SPOT instance : $INSTANCE_TYPE"
	# Calculate the price (second max + 0.01)
	PRICE=`instancePrice $INSTANCE_TYPE`

	# Generate the configuration json file to request the instance 
	sed 's/SYSTEM_IMAGE/'$SYSTEM_IMAGE'/g;s/INSTANCE_TYPE/'$INSTANCE_TYPE'/g' spot-instance-launch-specification.json > temp.json
	
	# Request a spot instance and catch the request id so that we can manage it later.
	REQUEST_ID=`aws ec2 request-spot-instances --spot-price "$PRICE" --instance-count 1 --launch-specification file://temp.json | grep -m 1 -o "sir-.\{8\}"`

	# Check if the request has been send correctly
	if [ -z $REQUEST_ID ]; then
		echo "Not able to request the spot instance, please check if the given instance type is avaliable in our Image."
		exit 1
	fi 

	# Remove the temp configaration file and print out the result.
	rm temp.json
	echo "Requested a new $INSTANCE_TYPE spot instance: "
	echo "REQUEST_ID : $REQUEST_ID."
	echo "At the price of: " $PRICE
	
	# Waite the request to be active
	# Please note that we assume every request can be fulfilled in this version, we do not handle failed cases, so please shut down the script after waiting for more than 10 mins and check the status of the request manually.
	REQUEST_STATUS=''
	while [ $REQUEST_STATUS -ne "fulfilled" ]
	do
		sleep 1
		REQUEST_STATUS = `aws ec2 describe-spot-instance-requests --spot-instance-request-ids $REQUEST_ID | grep "STATUS" | cut -f2`
		
	done

	# Get the instance of the active request so that we can connect to it through ssh
	INSTANCE_ID=`aws ec2 describe-spot-instance-requests --spot-instance-request-ids $REQUEST_ID | grep -m 1 -o "\bi-.\{8\}"`
fi




# attach the data volume to our instance
#aws ec2 attach-volume --volume-id $VOLUME_ID --instance-id $INSTANCE_ID --device /dev/sdf

# Start Instance only when the instance is stopped
STOPPED=`aws ec2 describe-instances --instance-ids $INSTANCE_ID | grep -m 1 -o "stopped"`
if [[ $STOPPED == "stopped" ]]
then  
	aws ec2 start-instances --instance-ids $INSTANCE_ID
fi

echo Catching Amazon machine ip address ...
# catch the server address
while [ -z $SERVER_ADDRESS ]
do
	# Wait the instance to start
	sleep 1

	# Get the ip address of the instance
	SERVER_ADDRESS=`aws ec2 describe-instances --instance-ids $INSTANCE_ID | grep -m 1 -o "ec2\-.*com"`
done

# Wait the instance to run
COUNT=0
RUNNING=""

echo Waiting Amazon machine to run ...
while [ -z $RUNNING ]
do
	# Wait the instance to start
	sleep 5
	COUNT=$COUNT+5

	# Get the ip address of the instance
	RUNNING=`aws ec2 describe-instances --instance-ids $INSTANCE_ID | grep -m 1 -o "running"`
	
#	if [ $COUNT > 60 ]
#	then
#		echo "waiting for instance running time out (>60s). Please try again"
#		exit 0
#	fi
done

# Connect to the instance
echo "connect to $SERVER_ADDRESS"
if [ $SFTP -eq 1 ]
then
	sftp -i $KEY ubuntu@$SERVER_ADDRESS
else
	# start a reverse tunnel when ssh to the server so that data can be transfered back from the remote instance.
	ssh -R 10000:127.0.0.1:22 -i $KEY ubuntu@$SERVER_ADDRESS
fi

code=$?
echo "terminate code: "$code



# Stop the instance after logout
read -p "Are you sure you want to stop the instance? <y/N> " prompt
if [[ $prompt == "y" || $prompt == "Y" || $prompt == "yes" || $prompt == "Yes" ]]
then
  aws ec2 stop-instances --instance-ids $INSTANCE_ID
fi

# detach the data volume after stopping the instance.
#ec2-detach-volume volume_id [--instance instance_id [--device device]] [--force]

#read -p "Are you sure you want to detach the data volume from the instance? <y/N> " prompt
#if [[ $prompt == "y" || $prompt == "Y" || $prompt == "yes" || $prompt == "Yes" ]]
#then
#  aws ec2 detach-volume --volume-id $VOLUME_ID
#else
#  exit 0
#fi

# This is the end of script
