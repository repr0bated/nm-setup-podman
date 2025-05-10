# Netmaker Setup with EMQX

This repository contains scripts and configurations for setting up a Netmaker server with EMQX as the MQTT broker.

## Prerequisites

- Podman
- Podman Compose
- OpenSSL
- A domain name (for SSL certificates)

## Installation

1. Clone the repository:
```bash
git clone https://github.com/yourusername/nm-setup-podman.git
cd nm-setup-podman
```

2. Run the setup script with your domain:
```bash
./scripts/nm-setup.sh your.domain.com
```

This will:
- Generate SSL certificates
- Create EMQX configuration
- Create Nginx configuration
- Generate podman-compose.yml

3. Create the pod and start services:
```bash
podman pod create --name netmaker -p 8081:8443 -p 8883:8883 -p 1883:1883 -p 8080:8080
podman-compose up -d
```

4. Configure EMQX:
```bash
podman exec netmaker-mq emqx_ctl users add netmaker netmaker
podman exec netmaker-mq emqx_ctl acl add username netmaker topic "#" allow
```

## Configuration

### Ports
- 8081: Netmaker API
- 8883: MQTT over SSL
- 1883: MQTT (unencrypted)
- 8080: Dashboard
- 8443: Nginx reverse proxy

### Environment Variables
You can customize the ports by passing them to the setup script:
```bash
./scripts/nm-setup.sh your.domain.com [server_port] [broker_port] [dashboard_port]
```

### SSL Certificates
The setup script generates self-signed certificates. For production use, replace them with proper SSL certificates.

## Directory Structure
```
.
├── config/               # Configuration files
│   ├── emqx.conf        # EMQX configuration
│   ├── nginx.conf       # Nginx configuration
│   ├── emqx-certs/      # EMQX certificates
│   └── selfsigned.*     # SSL certificates
├── scripts/
│   └── nm-setup.sh      # Setup script
└── podman-compose.yml   # Container configuration
```

## Security Notes
- The default EMQX credentials are set to `netmaker/netmaker`. Change these in production.
- The MASTER_KEY in podman-compose.yml needs to be replaced with a secure value.
- Self-signed certificates are used by default. Replace with proper SSL certificates for production.

## Troubleshooting

### EMQX Not Starting
If EMQX fails to start, check the logs:
```bash
podman logs netmaker-mq
```

### Certificate Issues
If you encounter SSL certificate issues:
1. Verify the certificates are properly generated
2. Check the certificate paths in the configurations
3. Ensure the domain names match your certificates

## License
[Your chosen license]
