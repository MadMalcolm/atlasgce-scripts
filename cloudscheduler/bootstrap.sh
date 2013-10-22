#!/usr/bin/env sh

message()
{
  echo "INFO: $1"
}

error()
{
  echo "ERROR: $1" 1>&2
  exit $2
}

mount_script=/var/run/mount.sh
node_template=/var/run/node-template.pp

cat << "__EOF__" > $mount_script
#!/usr/bin/env sh

format_and_mount()
{
  echo "Creating logical volume $1 with $3 and mount point $2..."
  lvcreate $3 --name $1 vg00
  mkdir -p $2
  /usr/share/google/safe_format_and_mount -m "mkfs.ext4 -F -m 2" /dev/vg00/$1 $2
}

DISK_PATH=/dev/disk/by-id/google-ephemeral-disk-
for disk in $DISK_PATH*
do
  echo "Creating physical volumes (pvcreate)..."
  pvcreate $disk
done

echo "Creating volume group (vgcreate)..."
vgcreate vg00 $DISK_PATH*

format_and_mount lv_cvmfs /var/cache/cvmfs2 "--size 30G"
format_and_mount lv_condor /var/lib/condor "--extents 100%FREE"
__EOF__



cat << "__EOF__" > $node_template
# Mounts and node template for a gce worker node

# Cache for CVMFS
mount {'/var/cache/cvmfs2':
    device => '/dev/vg00/lv_cvmfs',
    fstype => 'ext4',
    options => 'defaults',
    ensure => mounted,
    dump => 1,
    pass => 2,
}

# Cache for scheduler
mount {'/var/lib/condor':
    device => '/dev/vg00/lv_condor',
    fstype => 'ext4',
    options => 'defaults',
    ensure => mounted,
    dump => 1,
    pass => 2,
}

class { 'gce_node':
  head => 'to.be.contextualized.by.cloud.scheduler',
  role => 'csnode',
  use_cvmfs => true,
  condor_pool_password => undef,
  condor_use_gsi => true,
  condor_slots => 32,
  use_xrootd => false,
  condor_vmtype => 'atlas-batch-node',
  cvmfs_domain_servers => "http://cvmfs.racf.bnl.gov:8000/opt/@org@;http://cvmfs.fnal.gov:8000/opt/@org@;http://cvmfs-stratum-one.cern.ch:8000/opt/@org@;http://cernvmfs.gridpp.rl.ac.uk:8000/opt/@org@;http://cvmfs02.grid.sinica.edu.tw:8000/opt/@org@"
}
__EOF__

install_puppet()
{
  message "Retrieving puppet package file..."
  rpm -ivh http://yum.puppetlabs.com/el/6/products/i386/puppetlabs-release-6-6.noarch.rpm

  message "Installing puppet..."
  yum -y install puppet-2.7.21
}

install_puppet_modules()
{
  message "Installing puppet modules..."
  puppet module install thias/sysctl
}

install_extras()
{
  message "Installing git..."
  yum -y install git
}

if [ $(id -u) -ne 0 ]
then
  error "Must run as root" 1
fi

install_puppet
install_extras

message "Formatting and mounting extra ephemeral disks..."
sh $mount_script

message "Fetching puppet modules for GCE..."
git clone https://github.com/MadMalcolm/atlasgce-modules.git /etc/puppet/modules

# Install puppet modules after having cloned the atlasgce modules, since git
# will balk at cloning to a non-empty directory
install_puppet_modules

message "Fetching and applying node template..."
puppet apply $node_template
