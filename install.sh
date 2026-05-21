#!/usr/bin/env bash
set -Eeuo pipefail

REPO="break-edu/breakedu-site-proto3"
WORKDIR="${WORKDIR:-$HOME/breakedu-site-proto3}"

info() { printf "\n\033[1;34m==>\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33mWARN:\033[0m %s\n" "$*" >&2; }
fail() { printf "\n\033[1;31mERROR:\033[0m %s\n" "$*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "필수 명령어가 없습니다: $1"
}

confirm() {
  read -r -p "$1 [y/N] " ans
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

install_tailscale() {
  if command -v tailscale >/dev/null 2>&1; then
    info "Tailscale이 이미 설치되어 있습니다: $(tailscale version | head -n1)"
  else
    info "Tailscale을 설치합니다"

    # Tailscale 공식 Linux 설치 스크립트.
    # Ubuntu에서는 공식 APT 저장소 등록 후 tailscale 패키지를 설치합니다.
    curl -fsSL https://tailscale.com/install.sh | sh
  fi

  info "tailscaled 서비스를 활성화합니다"
  sudo systemctl enable --now tailscaled
}

tailscale_up() {
  info "Tailscale 로그인 상태를 확인합니다"

  if tailscale status >/dev/null 2>&1; then
    info "이미 Tailscale에 연결되어 있습니다"
    tailscale status
    return
  fi

  warn "브라우저 로그인 URL이 출력됩니다. 해당 URL로 접속해 이 서버를 Tailnet에 등록하세요."
  sudo tailscale up

  info "Tailscale 연결 상태"
  tailscale status
}

install_base_packages() {
  info "기본 패키지를 설치합니다"
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl gnupg lsb-release git
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    info "Docker가 이미 설치되어 있습니다: $(docker --version)"
  else
    info "Docker 공식 APT 저장소를 등록하고 설치합니다"

    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg

    . /etc/os-release
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
      | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi

  info "Docker 실행 가능 여부를 확인합니다"
  sudo docker run --rm hello-world >/dev/null
  info "Docker OK"

  if ! groups "$USER" | grep -qw docker; then
    warn "현재 사용자는 docker 그룹에 없습니다. 매번 sudo 없이 Docker를 쓰려면 그룹 추가가 필요합니다."
    if confirm "현재 사용자를 docker 그룹에 추가할까요? 적용은 재로그인 후 반영됩니다."; then
      sudo usermod -aG docker "$USER"
      warn "docker 그룹 추가 완료. 이 터미널에서는 아직 sudo가 필요할 수 있습니다."
    fi
  fi
}

install_gh() {
  if command -v gh >/dev/null 2>&1; then
    info "GitHub CLI가 이미 설치되어 있습니다: $(gh --version | head -n1)"
  else
    info "GitHub CLI 공식 APT 저장소를 등록하고 설치합니다"

    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
    sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null

    sudo apt-get update
    sudo apt-get install -y gh
  fi
}

install_cloudflared() {
  if command -v cloudflared >/dev/null 2>&1; then
    info "cloudflared가 이미 설치되어 있습니다: $(cloudflared --version)"
    return
  fi

  info "cloudflared 최신 deb 패키지를 설치합니다"

  arch="$(dpkg --print-architecture)"
  case "$arch" in
    amd64) deb_arch="amd64" ;;
    arm64) deb_arch="arm64" ;;
    armhf) deb_arch="arm" ;;
    *) fail "지원하지 않는 아키텍처입니다: $arch" ;;
  esac

  tmp_deb="$(mktemp)"
  curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${deb_arch}.deb" -o "$tmp_deb"
  sudo dpkg -i "$tmp_deb" || sudo apt-get install -f -y
  rm -f "$tmp_deb"
}

github_login() {
  info "GitHub 로그인을 확인합니다"

  if gh auth status >/dev/null 2>&1; then
    info "이미 GitHub에 로그인되어 있습니다"
  else
    warn "브라우저 또는 one-time code 방식으로 GitHub 로그인을 진행합니다."
    gh auth login
  fi

  gh auth setup-git
  gh auth status
}

setup_cloudflare_tunnel() {
  info "Cloudflare Tunnel 설정"

  if systemctl list-unit-files | grep -q '^cloudflared.service'; then
    warn "cloudflared.service가 이미 존재합니다."
    if ! confirm "기존 서비스를 유지하고 다음 단계로 넘어갈까요?"; then
      fail "사용자가 중단했습니다"
    fi
    return
  fi

  warn "Cloudflare Zero Trust 대시보드에서 발급받은 Tunnel token을 붙여넣습니다."
  warn "토큰은 화면에 표시하지 않습니다. 스크립트에도 저장하지 않습니다."

  read -r -s -p "Cloudflare Tunnel token: " CF_TUNNEL_TOKEN
  printf "\n"

  [[ -n "$CF_TUNNEL_TOKEN" ]] || fail "Tunnel token이 비어 있습니다"

  sudo cloudflared service install "$CF_TUNNEL_TOKEN"
  unset CF_TUNNEL_TOKEN

  sudo systemctl enable --now cloudflared
  sudo systemctl status cloudflared --no-pager || true
}

choose_branch() {
  info "원격 브랜치 목록을 불러옵니다"

  mapfile -t branches < <(
    gh api "repos/${REPO}/branches" --paginate --jq '.[].name'
  )

  [[ "${#branches[@]}" -gt 0 ]] || fail "브랜치 목록을 가져오지 못했습니다"

  echo
  echo "클론할 브랜치를 선택하세요:"
  select branch in "${branches[@]}"; do
    if [[ -n "${branch:-}" ]]; then
      echo "$branch"
      return
    fi
    echo "올바른 번호를 선택하세요."
  done
}

clone_repo() {
  branch="$1"

  if [[ -d "$WORKDIR/.git" ]]; then
    warn "이미 Git 저장소가 있습니다: $WORKDIR"
    if confirm "기존 디렉터리에서 fetch/checkout을 진행할까요?"; then
      cd "$WORKDIR"
      git fetch origin
      git checkout "$branch"
      git pull --ff-only origin "$branch"
      return
    else
      fail "기존 디렉터리 때문에 중단했습니다"
    fi
  fi

  info "레포를 클론합니다: ${REPO} / branch=${branch}"
  gh repo clone "$REPO" "$WORKDIR" -- --branch "$branch"
}

run_deploy() {
  cd "$WORKDIR"

  [[ -f "./deploy.sh" ]] || fail "deploy.sh를 찾을 수 없습니다: $WORKDIR/deploy.sh"

  info "deploy.sh를 실행합니다"
  chmod +x ./deploy.sh
  ./deploy.sh
}

main() {
  [[ "$(uname -s)" == "Linux" ]] || fail "Linux에서만 실행할 수 있습니다"
  [[ -f /etc/os-release ]] || fail "/etc/os-release를 찾을 수 없습니다"

  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || warn "Ubuntu 기준 스크립트입니다. 현재 OS: ${PRETTY_NAME:-unknown}"

  need_cmd curl
  need_cmd sudo

  install_base_packages
  install_docker
  install_gh
  install_cloudflared
  install_tailscale

  github_login
#   setup_cloudflare_tunnel
#   tailscale_up

  branch="$(choose_branch)"
  clone_repo "$branch"
  run_deploy

  info "완료되었습니다"
}

main "$@"
