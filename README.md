# Complexitree-Website-Init

The repository contains the init-script to start the website for Complexitree. Follow the instructions to start.

## Install on a clean linux server

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Complexitree/website-init/refs/heads/main/setup.sh)"
```

## Updating the server

If selected in the setup the server updates the docker containers automatically. You may see update-information with this command:

```bash
journalctl -t docker-update
```

You may update the server manually by this command:

```bash
bash /opt/docker-setup/update-containers.sh
```
