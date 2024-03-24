terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Config Provider
provider "aws" {
  region                   = "us-east-1"
  profile                  = "fiap"
}

# VPC
resource "aws_vpc" "hack_main" {
  cidr_block = "10.0.0.0/23" # 512 IPs 
  tags = {
    Name = "hack-vpc"
  }
}

# public subnet 1
resource "aws_subnet" "hack_subnet_1" {
  vpc_id                  = aws_vpc.hack_main.id
  cidr_block              = "10.0.0.0/27"
  map_public_ip_on_launch = true
  availability_zone       = "us-east-1a"
}

# public subnet 2
resource "aws_subnet" "hack_subnet_2" {
  vpc_id                  = aws_vpc.hack_main.id
  cidr_block              = "10.0.0.32/27"
  map_public_ip_on_launch = true
  availability_zone       = "us-east-1b"
}

# private subnet 1
resource "aws_subnet" "hack_subnet_3" {
  vpc_id                  = aws_vpc.hack_main.id
  cidr_block              = "10.0.1.0/27"
  map_public_ip_on_launch = false
  availability_zone       = "us-east-1b"
}

# Internet Gateway
resource "aws_internet_gateway" "hack_gw" {
  vpc_id = aws_vpc.hack_main.id
}

# public subnet table route
resource "aws_route_table" "hack_route_public" {
  vpc_id = aws_vpc.hack_main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.hack_gw.id
  }
}

# add public subnet 1 in table route
resource "aws_route_table_association" "hack_rota1" {
  subnet_id      = aws_subnet.hack_subnet_1.id
  route_table_id = aws_route_table.hack_route_public.id
}

# add public subnet 2 in table route
resource "aws_route_table_association" "hack_rota2" {
  subnet_id      = aws_subnet.hack_subnet_2.id
  route_table_id = aws_route_table.hack_route_public.id
}

# Nat

# Elastic Ip
resource "aws_eip" "hack_eip" {
  depends_on = [aws_internet_gateway.hack_gw]
  domain = "vpc"
  tags = {
    Name = "hack_EIP_NAT"
  }
}

# NAT Gateway
resource "aws_nat_gateway" "hack_nat_private_subnet" {
  allocation_id = aws_eip.hack_eip.id
  subnet_id     = aws_subnet.hack_subnet_1.id

  tags = {
    Name = "Hack NAT private subnet"
  }

  depends_on = [aws_internet_gateway.hack_gw]
}

resource "aws_route_table" "hack_route_table_private" {
  vpc_id = aws_vpc.hack_main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.hack_nat_private_subnet.id
  }
}

resource "aws_route_table_association" "hack_rota3" {
  subnet_id      = aws_subnet.hack_subnet_3.id
  route_table_id = aws_route_table.hack_route_table_private.id
}

# LoadBalancer
resource "aws_lb" "hack_lb" {
  name               = "hack-lb-asg"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.hack_sg_for_elb.id]
  subnets            = [aws_subnet.hack_subnet_1.id, aws_subnet.hack_subnet_2.id]
  depends_on         = [aws_internet_gateway.hack_gw]
}

resource "aws_lb_target_group" "hack_alb_tg" {
  name     = "hack-tf-lb-alb-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.hack_main.id
}

resource "aws_lb_listener" "hack_front_end" {
  load_balancer_arn = aws_lb.hack_lb.arn
  port              = "80"
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.hack_alb_tg.arn
  }
}

# EC2
resource "aws_launch_template" "hack_ec2_launch_templ" {
  name_prefix   = "hack_ec2_launch_templ"
  image_id      = "ami-00c39f71452c08778"
  instance_type = "t2.micro"
  # user_data     = filebase64("user_data.hack") # files to use in ec2 instance

  network_interfaces {
    associate_public_ip_address = false
    subnet_id                   = aws_subnet.hack_subnet_3.id
    security_groups             = [aws_security_group.hack_sg_for_ec2.id]
  }
  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "Hack-instance" # Name for the EC2 instances
    }
  }
}

# AWS Auto Scaling Config
resource "aws_autoscaling_group" "hack_asg" {
  # qty of instances
  desired_capacity = 3
  max_size         = 9
  min_size         = 2

  # Connect to the target group
  target_group_arns = [aws_lb_target_group.hack_alb_tg.arn]

  # EC2 instance in private sbnet
  vpc_zone_identifier = [
    aws_subnet.hack_subnet_3.id
  ]

  launch_template {
    id      = aws_launch_template.hack_ec2_launch_templ.id
    version = "$Latest"
  }
}

# Security Group

# Sg to elb
resource "aws_security_group" "hack_sg_for_elb" {
  name   = "hack-sg_for_elb"
  vpc_id = aws_vpc.hack_main.id
  
  ingress {
    description      = "Allow http request from anywhere"
    protocol         = "tcp"
    from_port        = 80
    to_port          = 80
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
  
  ingress {
    description      = "Allow https request from anywhere"
    protocol         = "tcp"
    from_port        = 443
    to_port          = 443
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

}

# sg to ec2
resource "aws_security_group" "hack_sg_for_ec2" {
  name   = "hack-sg_for_ec2"
  vpc_id = aws_vpc.hack_main.id

  ingress {
    description     = "Allow http request from Load Balancer"
    protocol        = "tcp"
    from_port       = 80 # range of
    to_port         = 80 # port numbers
    security_groups = [aws_security_group.hack_sg_for_elb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
