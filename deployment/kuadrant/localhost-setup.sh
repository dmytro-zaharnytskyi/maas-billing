#!/bin/bash

# Localhost setup script for Kuadrant Models-as-a-Service
# This script sets up port forwarding and provides access instructions

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}Setting up localhost access for Kuadrant Models-as-a-Service...${NC}"

# Function to check if port is available
check_port() {
    local port=$1
    if lsof -Pi :$port -sTCP:LISTEN -t >/dev/null 2>&1; then
        return 1  # Port is in use
    else
        return 0  # Port is available
    fi
}

# Function to start port forward in background
start_port_forward() {
    local service=$1
    local namespace=$2
    local local_port=$3
    local remote_port=$4
    local name=$5
    
    echo -e "${YELLOW}Starting port-forward for $name...${NC}"
    
    if check_port $local_port; then
        kubectl port-forward -n $namespace $service $local_port:$remote_port > /dev/null 2>&1 &
        local pid=$!
        echo $pid > /tmp/kuadrant-$name-port-forward.pid
        
        # Wait a moment for port-forward to establish
        sleep 2
        
        if ps -p $pid > /dev/null 2>&1; then
            echo -e "${GREEN}✓ $name port-forward started (PID: $pid)${NC}"
            echo -e "  Access at: http://localhost:$local_port"
        else
            echo -e "${RED}✗ Failed to start $name port-forward${NC}"
        fi
    else
        echo -e "${YELLOW}⚠ Port $local_port is already in use for $name${NC}"
    fi
}

# Function to stop existing port forwards
stop_port_forwards() {
    echo -e "${YELLOW}Stopping any existing port-forwards...${NC}"
    
    for pidfile in /tmp/kuadrant-*-port-forward.pid; do
        if [ -f "$pidfile" ]; then
            local pid=$(cat "$pidfile")
            if ps -p $pid > /dev/null 2>&1; then
                kill $pid
                echo -e "${GREEN}✓ Stopped port-forward (PID: $pid)${NC}"
            fi
            rm -f "$pidfile"
        fi
    done
}

# Function to show status
show_status() {
    echo -e "\n${YELLOW}Checking Kuadrant components status...${NC}"
    
    # Check if namespaces exist
    if ! kubectl get namespace istio-system > /dev/null 2>&1; then
        echo -e "${RED}✗ istio-system namespace not found${NC}"
        echo -e "  Run: ./istio-install.sh apply"
        return 1
    fi
    
    if ! kubectl get namespace kuadrant-system > /dev/null 2>&1; then
        echo -e "${RED}✗ kuadrant-system namespace not found${NC}"
        echo -e "  Run: kubectl apply -f 02-kuadrant-operator.yaml"
        return 1
    fi
    
    if ! kubectl get namespace llm > /dev/null 2>&1; then
        echo -e "${RED}✗ llm namespace not found${NC}"
        echo -e "  Run: kubectl apply -f 00-namespaces.yaml"
        return 1
    fi
    
    # Check Istio gateway
    if kubectl get svc istio-ingressgateway -n istio-system > /dev/null 2>&1; then
        echo -e "${GREEN}✓ Istio ingress gateway is running${NC}"
    else
        echo -e "${RED}✗ Istio ingress gateway not found${NC}"
        return 1
    fi
    
    # Check Kuadrant components
    if kubectl get pods -n kuadrant-system | grep -E "(limitador|authorino)" | grep Running > /dev/null 2>&1; then
        echo -e "${GREEN}✓ Kuadrant components are running${NC}"
    else
        echo -e "${YELLOW}⚠ Some Kuadrant components may not be ready${NC}"
    fi
    
    # Check if gateway exists
    if kubectl get gateway inference-gateway -n llm > /dev/null 2>&1; then
        echo -e "${GREEN}✓ Kuadrant gateway is configured${NC}"
    else
        echo -e "${YELLOW}⚠ Kuadrant gateway not found in llm namespace${NC}"
        echo -e "  Run: kubectl apply -f 04-gateway-configuration.yaml"
    fi
    
    return 0
}

# Main function
main() {
    case "${1:-start}" in
        "start")
            show_status
            if [ $? -ne 0 ]; then
                echo -e "\n${RED}Please fix the issues above before starting port-forwards${NC}"
                exit 1
            fi
            
            echo -e "\n${YELLOW}Setting up port-forwards for localhost access...${NC}"
            
            # Start main API gateway port-forward
            start_port_forward "svc/istio-ingressgateway" "istio-system" "8000" "80" "gateway"
            
            # Optional: Start monitoring port-forwards
            if kubectl get svc prometheus -n istio-system > /dev/null 2>&1; then
                start_port_forward "svc/prometheus" "istio-system" "9090" "9090" "prometheus"
            fi
            
            if kubectl get svc grafana -n istio-system > /dev/null 2>&1; then
                start_port_forward "svc/grafana" "istio-system" "3000" "3000" "grafana"
            fi
            
            # Start Keycloak if exists
            if kubectl get svc keycloak -n rh-sso > /dev/null 2>&1; then
                start_port_forward "svc/keycloak" "rh-sso" "8080" "8080" "keycloak"
            elif kubectl get svc rh-sso -n rh-sso > /dev/null 2>&1; then
                start_port_forward "svc/rh-sso" "rh-sso" "8080" "8080" "keycloak"
            fi
            
            echo -e "\n${GREEN}🎉 Localhost setup complete!${NC}"
            echo -e "\n${YELLOW}📋 Access Points:${NC}"
            echo -e "• API Gateway: http://localhost:8000"
            echo -e "• Granite Model: http://localhost:8000/granite/"
            echo -e "• Mistral Model: http://localhost:8000/mistral/"
            echo -e "• Nomic Embeddings: http://localhost:8000/nomic/"
            
            if check_port 9090; then
                echo -e "• Prometheus: http://localhost:9090"
            fi
            if check_port 3000; then
                echo -e "• Grafana: http://localhost:3000"
            fi
            if check_port 8080; then
                echo -e "• Keycloak: http://localhost:8080"
            fi
            
            echo -e "\n${YELLOW}💡 Useful Commands:${NC}"
            echo -e "• Test APIs: ./test-api.sh"
            echo -e "• Stop port-forwards: $0 stop"
            echo -e "• View status: $0 status"
            ;;
            
        "stop")
            stop_port_forwards
            echo -e "${GREEN}✓ All port-forwards stopped${NC}"
            ;;
            
        "status")
            show_status
            echo -e "\n${YELLOW}Active Port-forwards:${NC}"
            for pidfile in /tmp/kuadrant-*-port-forward.pid; do
                if [ -f "$pidfile" ]; then
                    local pid=$(cat "$pidfile")
                    local name=$(basename "$pidfile" .pid | sed 's/kuadrant-//' | sed 's/-port-forward//')
                    if ps -p $pid > /dev/null 2>&1; then
                        echo -e "${GREEN}✓ $name (PID: $pid)${NC}"
                    else
                        echo -e "${RED}✗ $name (PID: $pid - not running)${NC}"
                        rm -f "$pidfile"
                    fi
                fi
            done
            ;;
            
        "restart")
            echo -e "${YELLOW}Restarting port-forwards...${NC}"
            stop_port_forwards
            sleep 2
            main start
            ;;
            
        *)
            echo -e "${YELLOW}Usage: $0 {start|stop|status|restart}${NC}"
            echo -e ""
            echo -e "Commands:"
            echo -e "  start   - Start port-forwards for localhost access (default)"
            echo -e "  stop    - Stop all port-forwards"
            echo -e "  status  - Show component and port-forward status"
            echo -e "  restart - Stop and start port-forwards"
            ;;
    esac
}

# Check prerequisites
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}kubectl is required but not installed${NC}"
    exit 1
fi

# Run main function
main "$@"