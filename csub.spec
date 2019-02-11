Summary: csub wrapper for qsub and BLCR
Name: csub
Version: 2.1
Release: 1
BuildArch: noarch
License: GPL
Group: Applications/System
Source: %{name}-%{version}.tar.gz
BuildRoot: %{_tmppath}/%{name}-%{version}-%{release}-buildroot
Requires: dmtcp
%description
This repository contains code to generate a csub script, this is wrapper script around qsub and blcr,
which will take a command, and automatically checkpoint it. If a job is about to run out of it's wall
time, the script will use blcr to checkpoint all it's information, and resubmit it, until the command
is done. This currently does not work very well for multi threaded jobs, and not at all for mpi jobs.

%prep
%setup -q

%build
python makecsub.py
sed -i -e 's,/usr/bin/env ,/usr/bin/,' csub

%install
mkdir -p $RPM_BUILD_ROOT/usr/bin
install csub $RPM_BUILD_ROOT/usr/bin

%clean
rm -rf %{buildroot}

%files
%defattr(-,root,root,-)
/usr/bin/csub

%changelog
* Mon Feb 25 2016 Ward Poelmans <ward.poelmans@ugent.be>
- First rpm version
