#!/bin/bash -e

mkdir -p ~/.ssh
echo "$DEPLOYKEY" | base64 -d > ~/.ssh/id_ed25519
chmod 600 ~/.ssh/id_ed25519
eval $(ssh-agent)
ssh-add ~/.ssh/id_ed25519
ssh-keyscan web.sourceforge.net > ~/.ssh/known_hosts
chmod 600 ~/.ssh/known_hosts
echo "$GPGKEY" | base64 -d | gpg --import
gpg --keyserver hkps://keys.openpgp.org --refresh-keys
unset DEPLOYKEY GPGKEY

set -x

gpgkey_id=688E1D093C3638F588890D4450268311C7AD3F62
pacman-key --keyserver hkps://keys.openpgp.org -r $gpgkey_id
pacman-key --init
pacman-key --lsign-key $gpgkey_id
cat >> /etc/makepkg.conf <<- EOF
	PKGDEST=$HOME/repo
	PACKAGER="DDoSolitary <DDoSolitary@gmail.com>"
	GPGKEY=$gpgkey_id
	COMPRESSZST=(zstd -c -T12 --ultra -20 -)
	PKGEXT=.pkg.tar.zst
EOF

repo_name=${MSYSTEM,,}-ddosolitary
rsync_path=ddosolitary@web.sourceforge.net:/home/project-web/msys-repo/htdocs/${MSYSTEM,,}/
rsync -avJ -e ssh $rsync_path ~/repo/
if [ ! -f ~/repo/$repo_name.db ]; then
	touch ~/repo/$repo_name.db
	gpg --detach-sign --output ~/repo/$repo_name.db{.sig,}
fi
cat >> /etc/pacman.conf <<- EOF
	[$repo_name]
	Server = file://$HOME/repo
	SigLevel = Required
EOF
pacman -Sy

if [ "$MSYSTEM" == "MSYS" ]; then
	cd msys
else
	cd mingw
fi

for i in $(cat gpg-keyids); do
	set +e
	for j in $(seq 10); do
		gpg --keyserver keyserver.ubuntu.com --recv-keys "$i" \
			|| gpg --keyserver pool.sks-keyservers.net --recv-keys "$i" \
			&& break
		if [ "$j" == "10" ]; then exit 1; fi
		sleep 1
	done
	set -e
done

tmp1="$(mktemp)"
tmp2="$(mktemp)"
tsort build-order >> "$tmp1"
find . -maxdepth 2 -path '*/PKGBUILD' | xargs -n1 dirname | xargs -n1 basename | sort >> "$tmp2"
pkglist="$(cat "$tmp1") $(sort "$tmp1" | comm -3 - "$tmp2")"

build_err=0
tmp_res="$(mktemp)"
for i in $pkglist; do
	pushd "$i"
	set +e
	makepkg -sr --sign --needed --noconfirm
	makepkg_err=$?
	set -e
	echo "$i $makepkg_err" >> "$tmp_res"
	case $makepkg_err in
	0)
		for j in $(makepkg --packagelist); do
			pushd ~/repo
			repo-add -R -s $repo_name.db.tar.gz "$j"
			popd
		done
		pacman -Sy
		;;
	13)
		;;
	*)
		build_err=1
		;;
	esac
	popd
done

cat "$tmp_res"
if (( $build_err == 0 )); then
	rsync -avJ --delete -e ssh ~/repo/ $rsync_path
fi
exit $build_err
