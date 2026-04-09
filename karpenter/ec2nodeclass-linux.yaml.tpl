apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: linux
spec:
  # Amazon Linux 2023 — EKS-optimised, minimal, fast cold-start
  amiSelectorTerms:
    - alias: al2023@latest

  # IAM instance profile for nodes (created by the karpenter module)
  role: ${node_role_name}

  # Discover subnets and security groups by the cluster tag set in vpc.tf / eks.tf
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: ${cluster_name}

  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: ${cluster_name}

  # 30 GiB is sufficient for a POC (AL2023 base image is ~8 GiB).
  # Raise to 50-100 GiB in production if jobs cache large Docker layers.
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 30Gi
        volumeType: gp3
        iops: 3000
        throughput: 125
        encrypted: true
        deleteOnTermination: true

  tags:
    karpenter.sh/discovery: ${cluster_name}
    Name: ${cluster_name}-linux-runner
