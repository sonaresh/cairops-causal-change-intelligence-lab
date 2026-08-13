resource "aws_security_group" "dependency" {
  name        = "${local.name}-dependency-sg"
  description = "Dedicated CAIROps E4 dependency security group"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "HTTP from EKS nodes only"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${local.name}-dependency-sg", CAIROpsExperiment = "E4" }
}

resource "aws_instance" "dependency" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.public[0].id
  vpc_security_group_ids      = [aws_security_group.dependency.id]
  associate_public_ip_address = false
  user_data                   = <<-EOF
    #!/bin/bash
    cat >/tmp/server.py <<'PY'
    from http.server import BaseHTTPRequestHandler, HTTPServer
    import json, time
    class H(BaseHTTPRequestHandler):
      def do_GET(self):
        body=json.dumps({"ok": True, "source":"dependency-vm", "ts":time.time()}).encode()
        self.send_response(200); self.send_header("Content-Type","application/json"); self.send_header("Content-Length",str(len(body))); self.end_headers(); self.wfile.write(body)
      def log_message(self,*args): pass
    HTTPServer(("0.0.0.0",8080),H).serve_forever()
    PY
    nohup python3 /tmp/server.py >/var/log/cairops-dependency.log 2>&1 &
  EOF
  tags                        = { Name = "${local.name}-dependency", CAIROpsExperiment = "E4" }
}
