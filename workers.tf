### Worker Node IAM Role and Instance Profile
resource "aws_iam_role" "eks-worker" {
  name = "${var.cluster-name}-eks-worker"

  assume_role_policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
POLICY
}

resource "aws_iam_role_policy_attachment" "eks-worker-AmazonEKSWorkerNodePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = "${aws_iam_role.eks-worker.name}"
}

resource "aws_iam_role_policy_attachment" "eks-worker-AmazonEKS_CNI_Policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = "${aws_iam_role.eks-worker.name}"
}

resource "aws_iam_role_policy_attachment" "eks-worker-AmazonEC2ContainerRegistryReadOnly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = "${aws_iam_role.eks-worker.name}"
}

resource "aws_iam_instance_profile" "eks-worker" {
  name = "${var.cluster-name}-eks-worker"
  role = "${aws_iam_role.eks-worker.name}"
}

### Worker Node security groups
resource "aws_security_group" "eks-worker" {
  name        = "${var.cluster-name}-eks-worker"
  description = "Security group for all nodes in the cluster"
  vpc_id      = "${aws_vpc.eks-vpc.id}"

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = "${
    map(
     "Name", "${var.cluster-name}-eks-worker",
     "kubernetes.io/cluster/${var.cluster-name}", "owned",
    )
  }"
}

resource "aws_security_group_rule" "eks-worker-ingress-self" {
  description              = "Allow node to communicate with each other"
  from_port                = 0
  protocol                 = "-1"
  security_group_id        = "${aws_security_group.eks-worker.id}"
  source_security_group_id = "${aws_security_group.eks-worker.id}"
  to_port                  = 65535
  type                     = "ingress"
}

resource "aws_security_group_rule" "eks-worker-ingress-cluster" {
  description              = "Allow worker Kubelets and pods to receive communication from the cluster control plane"
  from_port                = 1025
  protocol                 = "tcp"
  security_group_id        = "${aws_security_group.eks-worker.id}"
  source_security_group_id = "${aws_security_group.eks-worker.id}"
  to_port                  = 65535
  type                     = "ingress"
}

### Worker Node Access to EKS Master Cluster
resource "aws_security_group_rule" "eks-cluster-ingress-node-https" {
  description              = "Allow pods to communicate with the cluster API Server"
  from_port                = 443
  protocol                 = "tcp"
  security_group_id        = "${aws_security_group.eks-worker.id}"
  source_security_group_id = "${aws_security_group.eks-worker.id}"
  to_port                  = 443
  type                     = "ingress"
}

### Worker Node AutoScaling Group
data "aws_ami" "eks-worker-ami" {
  filter {
    name   = "name"
    values = ["amazon-eks-node-v*"]
  }

  most_recent = true
  owners      = ["602401143452"] # Amazon Account ID
}

locals {
  eks-node-userdata = <<USERDATA
#!/bin/bash
set -o xtrace

/etc/eks/bootstrap.sh --apiserver-endpoint '${aws_eks_cluster.eks-master.endpoint}' --b64-cluster-ca '${aws_eks_cluster.eks-master.certificate_authority.0.data}' '${var.cluster-name}'
USERDATA
}

resource "aws_launch_configuration" "eks-worker-cluster" {
  associate_public_ip_address = true
  iam_instance_profile        = "${aws_iam_instance_profile.eks-worker.name}"
  image_id                    = "${data.aws_ami.eks-worker-ami.id}"
  instance_type               = "${var.node-instance-type}"
  name_prefix                 = "eks-cluster"
  security_groups             = ["${aws_security_group.eks-worker.id}"]
  user_data_base64            = "${base64encode(local.eks-node-userdata)}"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "eks-worker-cluster" {
  desired_capacity     = "${var.desiered-nodes}"
  max_size             = "${var.max-nodes}"
  min_size             = "${var.min-nodes}"
  launch_configuration = "${aws_launch_configuration.eks-worker-cluster.id}"
  name                 = "${var.cluster-name}-eks-cluster"
  vpc_zone_identifier  = ["${aws_subnet.eks-subnet.*.id}"]

  tag {
    key                 = "Name"
    value               = "${var.cluster-name}-eks-cluster"
    propagate_at_launch = true
  }

  tag {
    key                 = "kubernetes.io/cluster/${var.cluster-name}"
    value               = "owned"
    propagate_at_launch = true
  }
}