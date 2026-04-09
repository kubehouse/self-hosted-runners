apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: windows
spec:
  # Windows Server 2022 LTSC — EKS-optimised AMI
  # Karpenter resolves the latest EKS-compatible Windows 2022 AMI automatically.
  amiSelectorTerms:
    - alias: windows2022@latest

  role: ${node_role_name}

  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: ${cluster_name}

  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: ${cluster_name}

  # Windows Server 2022 base image is ~15 GiB; 60 GiB leaves room for build
  # artefacts without over-provisioning on a POC. Raise to 150 GiB in production.
  blockDeviceMappings:
    - deviceName: /dev/sda1
      ebs:
        volumeSize: 60Gi
        volumeType: gp3
        iops: 3000
        throughput: 125
        encrypted: true
        deleteOnTermination: true

  tags:
    karpenter.sh/discovery: ${cluster_name}
    Name: ${cluster_name}-windows-runner
