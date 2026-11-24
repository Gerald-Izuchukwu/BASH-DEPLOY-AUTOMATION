#!/bin/bash

set -euo pipefail

# Locate the directory containing this script
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Load configuration and helper functions
source "$SCRIPT_DIR/config.sh"

clone_repository() {
    log_info "Preparing deployment directory: $REPO_DIR"

    # Construct the authenticated Git URL. We strip 'https://' from the start
    # of GIT_REPO_URL to correctly form the URL with PAT embedded.
    local AUTH_URL="https://$PAT@${GIT_REPO_URL#https://}"

    # Check if the repository directory already exists and contains a .git folder
    if [[ -d "$REPO_DIR/.git" ]]; then
        log_info "Repository directory '$REPO_DIR' already exists. Performing git pull..."
        
        # Navigate to the repository directory
        cd "$REPO_DIR" || log_error "Failed to enter repository directory $REPO_DIR."
        
        # Ensure we are on the correct branch and pull the latest changes
        log_info "Checking out branch $BRANCH_NAME..."
        git checkout "$BRANCH_NAME" || log_error "Failed to checkout branch $BRANCH_NAME."
        
        log_info "Pulling latest changes..."
        git pull "$AUTH_URL" "$BRANCH_NAME" || log_error "Failed to pull latest changes for branch $BRANCH_NAME."
        # Remove any PAT saved in the remote URL by earlier runs
        git remote set-url origin "$GIT_REPO_URL"
        
        # Navigate back to the original script directory
        cd .. || log_error "Failed to navigate back from repository directory."

        log_success "Repository successfully updated via git pull."
    else
        log_info "Repository directory '$REPO_DIR' does not exist. Performing git clone..."
        
        # Clone the repository using the authenticated URL and specific branch
        git clone --branch "$BRANCH_NAME" "$AUTH_URL" "$REPO_DIR" || log_error "Failed to clone repository $GIT_REPO_URL."
        git -C "$REPO_DIR" remote set-url origin "$GIT_REPO_URL" || log_error "Failed to reset remote URL to original after cloning."
        
        log_success "Repository successfully cloned into $REPO_DIR."
    fi
}

change_into_repo_dir() {
    cd "$REPO_DIR" || log_error "Failed to change directory to $REPO_DIR."
    # check to see if Dockerfile or docker-compose.yaml exists
    if [[ ! -f "Dockerfile" || ( ! -f "docker-compose.yaml" && ! -f "docker-compose.yml" ) ]]; then
        log_error "No Dockerfile or docker-compose.yaml found in $REPO_DIR."
    fi
}

ssh_into_remote_server(){
    log_info "Attempting to SSH into remote server $SSH_USER@$SERVER_IP..."
    ssh -i "$SSH_KEY_PATH" -o BatchMode=yes -o ConnectTimeout=10 "$SSH_USER@$SERVER_IP" "echo 'SSH connection successful.'" \
        && log_success "SSH connection to $SERVER_IP succeeded." \
        || log_error "SSH connection to $SERVER_IP failed."
}

preparing_remote_environment(){
    log_info "Preparing remote environment on $SERVER_IP..."
    #update package lists
    log_info "Updating package lists on remote server..."
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" 'sudo apt update -y' || log_error "Failed to update package lists on remote server."
    #install docker, docker-compose and nginx
    log_info "Installing required packages (Docker, Docker-Compose, Nginx) on remote server..."
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" 'sudo apt install -y docker.io docker-compose nginx rsync' || log_error "Failed to install required packages on remote server."
    # add user to docker group
    log_info "Adding user $SSH_USER to docker group on remote server..."
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" "sudo usermod -aG docker $SSH_USER" || log_error "Failed to add user to docker group"
    # enable and start services
    log_info "Enabling and starting Docker and Nginx services on remote server..."
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" 'sudo systemctl enable docker && sudo systemctl start docker' || log_error "Failed to enable/start Docker service on remote server."
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" 'sudo systemctl enable nginx && sudo systemctl start nginx' || log_error "Failed to enable/start Nginx service on remote server."
    # confirm installations
    log_info "Verifying installations on remote server..."
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" 'docker --version' || log_error "Docker installation verification failed."
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" 'docker-compose --version' || log_error "Docker-Compose installation verification failed."
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" 'nginx -v' || log_error "Nginx installation verification failed."

    log_success "Remote environment prepared successfully."
}

deploy_dockerize_app(){
    log_info "Deploying Dockerized application on remote server..."

    #scp docker-compose.yaml and Dockerfile to remote server
    log_info "Copying Docker configuration files to remote server..."
    rsync -az --delete --exclude '.git' -e "ssh -i $SSH_KEY_PATH" ./ "$SSH_USER@$SERVER_IP:~/$REMOTE_DIR/" || log_error "Failed to copy project files to remote server."
    
    #build image and run container
    # log_info "Building Docker image and running container on remote server..."
    # ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" 'docker build -t my_app_image . && docker run -d -p '"$APP_PORT"':80 my_app_image' || log_error "Failed to build and run Docker container on remote server."
    
    # or using docker-compose
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" "cd ~/$REMOTE_DIR && docker-compose up -d --build" || log_error "Failed to deploy application using docker-compose on remote server."
   
    # validdate deployment
    log_info "Validating deployment on remote server..."
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" 'docker ps' || log_error "Failed to verify running Docker containers on remote server."
    
    # validate contianer health and logs
    log_info "Checking Docker container logs on remote server..."
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" "cd ~/$REMOTE_DIR && docker-compose logs --tail 20" || log_error "Failed to retrieve container logs on remote server."
   
    # confirm application is accessible
    log_info "Checking that the app answers on port $APP_PORT (from inside the server)..."
    local ok=0
    for i in 1 2 3 4 5 6; do
        if ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" "curl -fsS -o /dev/null http://localhost:$APP_PORT"; then
            ok=1
            break
        fi
        log_info "Not ready yet (attempt $i of 6), waiting 5 seconds..."
        sleep 5
    done
    if [[ $ok -eq 0 ]]; then
        ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" "cd ~/$REMOTE_DIR && docker-compose ps && docker-compose logs --tail 30" || true
        log_error "App is not answering on port $APP_PORT. Check that the left number in 'ports' in docker-compose.yaml is $APP_PORT."
    fi

    log_success "Dockerized application deployed successfully."
}

configuring_nginx_reverse_proxy() {
    log_info "Configuring Nginx as a reverse proxy on remote server..."

    local NGINX_CONFIG=$(cat <<EOF
    server {
        listen 80;
        server_name $SERVER_IP;

        location / {
            proxy_pass http://localhost:$APP_PORT;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }

        location /health {
            return 200 "OK\n";
            add_header Content-Type text/plain;
        }
    }
EOF
)

    log_info "Uploading Nginx configuration to remote server..."
    echo "$NGINX_CONFIG" | ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" \
        'sudo tee /etc/nginx/conf.d/reverse-proxy.conf >/dev/null' \
        || log_error "Failed to upload Nginx configuration to remote server."

    log_info "Testing Nginx configuration on remote server..."
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" 'sudo nginx -t' \
        || log_error "Nginx configuration test failed on remote server."

    log_info "Reloading Nginx on remote server..."
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" \
        'sudo nginx -s reload || sudo systemctl reload nginx' \
        || log_error "Failed to reload Nginx on remote server."

    log_info "Checking the app through Nginx..."
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" 'curl -fsS http://localhost/health && curl -fsS -o /dev/null http://localhost/' \
        || log_error "Nginx is running but the app did not answer through it."
    
    log_success "Nginx configured successfully as a reverse proxy."
}

# --- Main Execution ---

main() {
    echo "====================================================="
    echo "             Deployment Script Initialized             "
    echo "====================================================="
    log_info "All logs are being recorded in: $LOG_FILE"

    # 1. Collect and Validate Parameters
    collect_parameters

    # 2. Display Collected Parameters for Verification
    log_info "Deployment Configuration Summary:"
    log_info "---------------------------------"
    log_info "Git Repository URL: $GIT_REPO_URL"
    log_info "Git Branch:         $BRANCH_NAME"
    log_info "PAT:                *********** (Hidden)"
    log_info "SSH User:           $SSH_USER"
    log_info "Server IP:          $SERVER_IP"
    log_info "SSH Key Path:       $SSH_KEY_PATH"
    log_info "App Internal Port:  $APP_PORT"
    log_info "---------------------------------"

    #cloning the repository
    log_info "--- Step 1: Clone or update the repository locally ---"
    clone_repository

    #  Navigate into the cloned repository directory
    log_info "Changing into repository directory: $REPO_DIR"
    change_into_repo_dir

    # 3. Placeholder for Deployment Steps (e.g., SSH, Build, Deploy)
    log_info "Starting deployment to remote server..."
    #ssh into remote server
    ssh_into_remote_server
    #prepare remote environment
    preparing_remote_environment
    # deploy dockerized app 
    deploy_dockerize_app
    # configure nginx as reverse proxy
    configuring_nginx_reverse_proxy


    log_success "Script finished parameter collection and validation successfully. App is available at http://$SERVER_IP"
}

# Execute main function
main
