resource "aws_security_group" "allow_ssh" {
  name        = "allow_ssh"
  description = "Allow SSH inbound traffic"
  ingress {
    from_port = 80
    to_port = 80
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "active" {
  ami           = "ami-05f991c49d264708f"
  instance_type = "t3.micro"
  monitoring             = true
  key_name      = "keypairforubuntu"
  security_groups = [aws_security_group.allow_ssh.name]
  user_data     = <<-EOF
                    #!/bin/bash
                    echo "start" > /home/ubuntu/status.txt
                    sudo apt -y install nginx
                    sudo systemctl start nginx
                    sudo systemctl enable nginx
                  EOF
  tags = {
    Name = "active"
  }
}
resource "aws_instance" "passive" {
  ami           = "ami-05f991c49d264708f"
  instance_type = "t3.micro"
  monitoring             = true
  key_name      = "keypairforubuntu"
  security_groups = [aws_security_group.allow_ssh.name]
  user_data     = <<-EOF
                    #!/bin/bash
                    echo "start" > /home/ubuntu/status.txt
                    sudo apt -y install nginx
                    sudo systemctl start nginx
                    sudo systemctl enable nginx
                  EOF
  tags = {
    Name = "passive"
  }
}
  

resource "aws_eip" "eip" {
  instance = aws_instance.active.id
}


resource "aws_iam_role" "lambda_role" {
  name = "lambda-failover-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
      Effect = "Allow"
    }]
  })
}

resource "aws_iam_role" "lambda_role2" {
  name = "lambda-failover-role2"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
      Effect = "Allow"
    }]
  })
}




resource "aws_iam_role_policy" "lambda_policy" {
  name = "lambda-ec2-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "ec2:Describe*",
          "ec2:AssociateAddress",
          "ec2:DisassociateAddress"
        ]
        Effect   = "Allow"
        Resource = "*"
      },
      {
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Effect   = "Allow"
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "lambda_policy2" {
  name = "lambda-ec2-policy2"
  role = aws_iam_role.lambda_role2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "ec2:Describe*",
          "ec2:AssociateAddress",
          "ec2:DisassociateAddress"
        ]
        Effect   = "Allow"
        Resource = "*"
      },
      {
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Effect   = "Allow"
        Resource = "*"
      }
    ]
  })
}



data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda_function/failover.py"
  output_path = "${path.module}/lambda_function/failover.zip"
}

data "archive_file" "lambda_zip2" {
  type        = "zip"
  source_file = "${path.module}/lambda_function/failover2.py"
  output_path = "${path.module}/lambda_function/failover2.zip"
}


resource "aws_lambda_function" "failover" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "ec2-failover"
  role             = aws_iam_role.lambda_role.arn
  handler          = "failover.lambda_handler"
  runtime          = "python3.9"
  source_code_hash = filebase64sha256(data.archive_file.lambda_zip.output_path)
  timeout          = 15

  environment {
    variables = {
      ACTIVE_INSTANCE_ID   = aws_instance.active.id
      PASSIVE_INSTANCE_ID  = aws_instance.passive.id
      EIP_ALLOCATION_ID    = aws_eip.eip.allocation_id
    }
  }

  depends_on = [aws_iam_role_policy.lambda_policy]
}



resource "aws_lambda_function" "failover2" {
  filename         = data.archive_file.lambda_zip2.output_path
  function_name    = "ec2-failover2"
  role             = aws_iam_role.lambda_role2.arn
  handler          = "failover2.lambda_handler"
  runtime          = "python3.9"
  source_code_hash = filebase64sha256(data.archive_file.lambda_zip2.output_path)
  timeout          = 15

  environment {
    variables = {
      ACTIVE_INSTANCE_ID   = aws_instance.active.id
      PASSIVE_INSTANCE_ID  = aws_instance.passive.id
      EIP_ALLOCATION_ID    = aws_eip.eip.allocation_id
    }
  }

  depends_on = [aws_iam_role_policy.lambda_policy2]
}

resource "aws_sns_topic" "alarm_topic" {
  name = "cloudwatch-alarm-topic"
}

resource "aws_sns_topic" "alarm_topic2" {
  name = "cloudwatch-alarm-topic2"
}



resource "aws_cloudwatch_metric_alarm" "instance_down_alarm" {
  alarm_name          = "ActiveEC2Down"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "StatusCheckFailed_Instance"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Average"
  threshold           = 1
  treat_missing_data  = "breaching"
  alarm_description   = "Triggers failover Lambda if active instance is down"
  dimensions = {
    InstanceId = aws_instance.active.id
  }
  alarm_actions = [aws_sns_topic.alarm_topic.arn]
  depends_on = [aws_instance.active]
}

resource "aws_cloudwatch_metric_alarm" "instance_down_alarm2" {
  alarm_name          = "PassiveEC2Down"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "StatusCheckFailed_Instance"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Average"
  threshold           = 1
  treat_missing_data  = "breaching"
  alarm_description   = "Triggers failover Lambda if active instance is down"
  dimensions = {
    InstanceId = aws_instance.passive.id
  }
  alarm_actions = [aws_sns_topic.alarm_topic2.arn]
  depends_on = [aws_instance.passive]
}


resource "aws_lambda_permission" "allow_sns" {
  statement_id  = "AllowExecutionFromSNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.failover.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.alarm_topic.arn
}

resource "aws_lambda_permission" "allow_sns2" {
  statement_id  = "AllowExecutionFromSNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.failover2.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.alarm_topic2.arn
}

resource "aws_sns_topic_subscription" "lambda_sub" {
  topic_arn = aws_sns_topic.alarm_topic.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.failover.arn
}

resource "aws_sns_topic_subscription" "lambda_sub2" {
  topic_arn = aws_sns_topic.alarm_topic2.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.failover2.arn
}


resource "aws_s3_bucket" "image_bucket" {
  bucket = "sr71blackbird-bucket-example"

  tags = {
    Name = "SR71 Bucket"
  }
}


resource "aws_s3_bucket_public_access_block" "block" {
  bucket                  = aws_s3_bucket.image_bucket.id
  block_public_acls       = true
  block_public_policy     = false
  ignore_public_acls      = true
  restrict_public_buckets = false
}


resource "aws_s3_bucket_policy" "cloudfront_policy" {
  bucket = aws_s3_bucket.image_bucket.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowCloudFrontServicePrincipalReadOnly"
        Effect    = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.image_bucket.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.cdn.arn
          }
        }
      }
    ]
  })
}


resource "aws_s3_object" "upload_image" {
  bucket = aws_s3_bucket.image_bucket.id
  key    = "SR71Blackbird.jpg"
  source = "SR71Blackbird.jpg"
  content_type = "image/jpeg"
  etag   = filemd5("SR71Blackbird.jpg")
}


resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = "OACforS3"
  description                       = "Access Control for CloudFront to access S3"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}


resource "aws_cloudfront_distribution" "cdn" {
  origin {
    domain_name = aws_s3_bucket.image_bucket.bucket_regional_domain_name
    origin_id   = "s3Origin"

    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id
  }

  enabled             = true
  default_root_object = "SR71Blackbird.jpg"

  default_cache_behavior {
    target_origin_id       = "s3Origin"
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["GET", "HEAD"]
    cached_methods  = ["GET", "HEAD"]

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    min_ttl     = 0
    default_ttl = 3600
    max_ttl     = 86400
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  tags = {
    Name = "SR71 CloudFront"
  }
}

output "cloudfront_domain_name" {
  value = aws_cloudfront_distribution.cdn.domain_name
}

locals {
  rendered_html = templatefile("${path.module}/index.html.tpl", {
    cloudfront_domain = aws_cloudfront_distribution.cdn.domain_name
  })
}

resource "local_file" "html_output" {
  content  = local.rendered_html
  filename = "${path.module}/index.html"
}


resource "null_resource" "copy_html_web1" {
  depends_on = [aws_instance.active,aws_eip.eip,local_file.html_output]
  provisioner "file" {
    source      = "${path.module}/index.html"
    destination = "/home/ubuntu/index.html"

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = file("keypairforubuntu.pem")
      host        = aws_eip.eip.public_ip
    }
  }
  provisioner "remote-exec" {
    inline = [
      "sudo mv /home/ubuntu/index.html /var/www/html/index.html",
      "sudo systemctl restart nginx"
    ]
    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = file("keypairforubuntu.pem")
      host        = aws_eip.eip.public_ip
    }
  }
}

resource "null_resource" "copy_html_web2" {
  depends_on = [aws_instance.passive,local_file.html_output]
  
  provisioner "file" {
    source      = "${path.module}/index.html"
    destination = "/home/ubuntu/index.html"

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = file("keypairforubuntu.pem")
      host        = aws_instance.passive.public_ip
    }
  }

  
  provisioner "remote-exec" {
    inline = [
      "sudo mv /home/ubuntu/index.html /var/www/html/index.html",
      "sudo systemctl restart nginx"
    ]

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = file("keypairforubuntu.pem")
      host        = aws_instance.passive.public_ip
    }
  }
}


