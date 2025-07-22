# vps
Smart-R Traefik with Docker for VPS

[smarthomebeginner](https://www.smarthomebeginner.com/traefik-2-docker-tutorial/)

## 01 setup

### Check running containers
- sudo docker ps
    - sudo docker-compose -f docker-compose-t3.yml down
- sudo docker stack ls
    - sudo docker stack rm traefik
- sudo docker network ls
    - sudo docker network create t2_proxy

### one-off    
- git clone git@github.com:Fpadt/vps.git

### test
- sudo docker-compose -f docker-compose-t3.yml up -d
- sudo docker logs -tf --tail="50" traefik2

### Dashboard

#### http
- [Dashboard localhost](http://localhost:8080/dashboard/#/)
- [Dashboard TitanToad](http://titantoad:8080/dashboard/#/)

#### https
- [404 page not found](https://localhost:8080/dashboard/#/)
- [404 page not found](https://titantoad:8080/dashboard/#/)



