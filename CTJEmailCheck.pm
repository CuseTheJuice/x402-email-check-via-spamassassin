package Mail::SpamAssassin::Plugin::CTJEmailCheck;

use strict;
use warnings;

use Mail::SpamAssassin::Plugin;
use Mail::SpamAssassin::Conf;
use Mail::SpamAssassin::Logger;

use HTTP::Tiny;
use JSON::PP;
use URI::Escape qw(uri_escape);
use Cwd qw(abs_path);

our @ISA = qw(Mail::SpamAssassin::Plugin);

sub new {
  my ($class, $mailsa) = @_;

  my $self = $class->SUPER::new($mailsa);
  bless($self, $class);

  # header eval rule(s)
  $self->register_eval_rule(
    'ctj_email_check_header',
    $Mail::SpamAssassin::Conf::TYPE_HEAD_EVALS
  );

  return $self;
}

sub parse_config {
  my ($self, $opts) = @_;

  my $key = $opts->{key};
  my $value = $opts->{value};
  my $conf = $opts->{conf};

  if ($key eq 'ctj_email_check_api_url') {
    $conf->{ctj_email_check_api_url} = $value;
    $self->inhibit_further_callbacks();
    return 1;
  }

  if ($key eq 'ctj_email_check_timeout_seconds') {
    $conf->{ctj_email_check_timeout_seconds} = $value + 0;
    $self->inhibit_further_callbacks();
    return 1;
  }

  if ($key eq 'ctj_email_check_script_path') {
    $conf->{ctj_email_check_script_path} = $value;
    $self->inhibit_further_callbacks();
    return 1;
  }

  if ($key eq 'ctj_email_check_script_python_bin') {
    $conf->{ctj_email_check_script_python_bin} = $value;
    $self->inhibit_further_callbacks();
    return 1;
  }

  if ($key eq 'ctj_email_check_script_endpoint') {
    $conf->{ctj_email_check_script_endpoint} = $value;
    $self->inhibit_further_callbacks();
    return 1;
  }

  return 0;
}

sub _extract_email_addresses {
  my ($header_value) = @_;
  return () if !defined $header_value || $header_value eq '';

  my $LOCAL_PART_RE = qr/[A-Za-z0-9.!#$%&'*+\/=?^_`{|}~-]+/;
  my $DOMAIN_RE =
    qr/[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+/;

  my @matches;
  while (
    $header_value =~
      /($LOCAL_PART_RE\@$DOMAIN_RE)/g
  ) {
    push @matches, $1;
  }

  return @matches;
}

sub _analyze_email_local {
  my ($raw) = @_;
  $raw = '' if !defined $raw;

  my @issues;

  if (length($raw) == 0) {
    return { valid => 0, issues => ['Input is empty.'], normalizedEmail => undef };
  }

  my $trimmed = $raw;
  $trimmed =~ s/^\s+//;
  $trimmed =~ s/\s+$//;

  if (length($trimmed) == 0) {
    return { valid => 0, issues => ['Address is empty or whitespace only.'], normalizedEmail => undef };
  }

  if ($trimmed ne $raw) {
    push @issues, 'Remove leading or trailing whitespace.';
  }

  if ($trimmed =~ /\s/) {
    push @issues, 'Email must not contain spaces or other whitespace.';
  }

  if (length($trimmed) > 254) {
    push @issues, 'Total length exceeds 254 characters (RFC 5321 practical limit).';
  }

  my $atCount = ($trimmed =~ tr/@/@/);
  if ($atCount != 1) {
    if ($atCount == 0) {
      push @issues, 'Missing "@" between the mailbox name and the domain.';
    }
    else {
      push @issues, 'Exactly one @ is required.';
    }

    return { valid => 0, issues => \@issues, normalizedEmail => undef };
  }

  my $at_index = index($trimmed, '@');
  my $local = substr($trimmed, 0, $at_index);
  my $domain = substr($trimmed, $at_index + 1);

  if (length($local) == 0) {
    push @issues, 'Local part (before @) is empty.';
  }
  else {
    if (length($local) > 64) {
      push @issues, 'Local part exceeds 64 characters.';
    }
    if (substr($local, 0, 1) eq '.' || substr($local, -1, 1) eq '.') {
      push @issues, 'Local part must not start or end with a dot.';
    }
    if ($local =~ /\.\./) {
      push @issues, 'Local part must not contain consecutive dots.';
    }

    my $LOCAL_PART_RE = qr/^[A-Za-z0-9.!#\$%&'\*\+\/=\?\^_\`\{\|\}\~\-]+$/;
    if ($local !~ $LOCAL_PART_RE) {
      push @issues, 'Local part contains characters or patterns outside the allowed set for this check.';
    }
  }

  if (length($domain) == 0) {
    push @issues, 'Domain (after @) is empty.';
  }
  else {
    if ($domain =~ /\.\./) {
      push @issues, 'Domain must not contain consecutive dots.';
    }
    if (substr($domain, 0, 1) eq '.' || substr($domain, -1, 1) eq '.') {
      push @issues, 'Domain must not start or end with a dot.';
    }
    if ($domain !~ /\./) {
      push @issues, 'Domain should include a hostname and TLD (e.g. example.com).';
    }

    my @labels = split(/\./, $domain);
    @labels = grep { $_ ne '' } @labels;

    if (grep { length($_) > 63 } @labels) {
      push @issues, 'Each domain label must be at most 63 characters.';
    }

    my $tld = $labels[-1];
    if (defined $tld && length($tld) > 0 && length($tld) < 2) {
      push @issues, 'Top-level domain should be at least 2 characters.';
    }

    my $DOMAIN_RE = qr/^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$/;
    if ($domain !~ $DOMAIN_RE) {
      push @issues, 'Domain is not a valid hostname-style format for this validator.';
    }
  }

  if ($trimmed =~ /[^\x00-\x7F]/) {
    push @issues, 'Non-ASCII characters present; this endpoint validates a common ASCII profile only.';
  }

  my $valid = scalar(@issues) == 0;
  return {
    valid => $valid ? 1 : 0,
    issues => $valid ? [] : \@issues,
    normalizedEmail => $valid ? lc($trimmed) : undef
  };
}

sub _analyze_email_via_api {
  my ($api_url, $email, $timeout_seconds) = @_;

  # The API expects `?email=...` and returns JSON like:
  # { result: { valid: boolean, issues: [...], normalizedEmail: string|null }, error?: string }
  my $ua = HTTP::Tiny->new(
    timeout => ($timeout_seconds && $timeout_seconds > 0) ? $timeout_seconds : 2,
    agent   => 'SpamAssassin/CTJEmailCheck',
  );

  my $url = $api_url;
  $url .= ($url =~ /\?/) ? '&' : '?';
  $url .= 'email=' . uri_escape($email);

  my $res = $ua->get($url, { headers => { 'Accept' => 'application/json' } });
  return undef if !$res || !$res->{success};

  return undef if ($res->{status} != 200);

  my $decoded = eval { JSON::PP::decode_json($res->{content}) };
  return undef if !$decoded || ref($decoded) ne 'HASH';

  my $result = $decoded->{result};
  if (!$result || ref($result) ne 'HASH') {
    return undef;
  }

  return $result->{valid} ? 1 : 0 if exists $result->{valid};
  return undef;
}

sub _analyze_email_via_script {
  my ($python_bin, $script_path, $endpoint, $email, $timeout_seconds) = @_;

  return undef if !$script_path || $script_path eq '';
  my $resolved = abs_path($script_path) || $script_path;
  return undef if !-f $resolved;

  $python_bin = 'python3' if !$python_bin || $python_bin eq '';
  $endpoint = 'https://app.cusethejuice.com/api/bots/email-check' if !$endpoint || $endpoint eq '';
  $timeout_seconds = ($timeout_seconds && $timeout_seconds > 0) ? $timeout_seconds : 2;

  # SpamAssassin runs with Perl taint mode (-T). When we spawn an external process,
  # we must ensure command arguments derived from message content (like $email)
  # are untainted, otherwise -T warns about "Insecure dependency in piped open".
  #
  # Since taint-mode might still consider config-derived values tainted, we
  # untaint *all* arguments we pass to the external command using strict
  # regex captures.

  # Python binary & script path: absolute paths and safe characters.
  my ($untainted_python_bin) =
    ($python_bin =~ m{^(\/[\w\.\-\/]+)$}) ? $1 : ();
  my ($untainted_resolved) =
    ($resolved =~ m{^(\/[\w\.\-\/]+)$}) ? $1 : ();
  return undef if !$untainted_python_bin || !$untainted_resolved;

  # Endpoint URL: allow standard http(s) URL characters.
  my ($untainted_endpoint) =
    ($endpoint =~ m{^(https?://[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]+)$}) ? $1 : ();
  return undef if !$untainted_endpoint;

  # Timeout: numeric (integer or decimal).
  my ($untainted_timeout) =
    ($timeout_seconds =~ m{^(\d+(?:\.\d+)?)$}) ? $1 : ();
  return undef if !$untainted_timeout;

  # The $email values come from _extract_email_addresses(); validate using a
  # compatible profile to safely untaint.
  my $LOCAL_PART_RE = qr/[A-Za-z0-9.!#$%&'*+\/=?^_`{|}~-]+/;
  my $DOMAIN_RE =
    qr/[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+/;

  my ($untainted_email) = ();
  if (defined $email && $email =~ /^($LOCAL_PART_RE\@$DOMAIN_RE)$/) {
    $untainted_email = $1; # captured group is untainted
  }
  else {
    return undef;
  }

  my @cmd = (
    $untainted_python_bin,
    $untainted_resolved,
    '--email', $untainted_email,
    '--endpoint', $untainted_endpoint,
    '--timeout', $untainted_timeout,
  );

  my $output = '';
  if (open(my $fh, '-|', @cmd)) {
    local $/;
    $output = <$fh>;
    close($fh);
    return undef if $? != 0;
  }
  else {
    return undef;
  }

  my $decoded = eval { JSON::PP::decode_json($output) };
  return undef if !$decoded || ref($decoded) ne 'HASH';
  return undef if !exists $decoded->{valid};
  return $decoded->{valid} ? 1 : 0;
}

sub ctj_email_check_header {
  my ($self, $permsgstatus, @args) = @_;

  my $header_name = $args[0] // 'From';
  # SpamAssassin eval rules may pass literal args including quotes;
  # normalize to a plain header name for `$permsgstatus->get()`.
  if (defined $header_name) {
    $header_name =~ s/^['"]//;
    $header_name =~ s/['"]$//;
  }
  my $conf = $permsgstatus->{main}->{conf};

  my $cache = $permsgstatus->{ctj_email_check_cache} ||= {};
  my $cache_key = "header=" . $header_name;
  return $cache->{$cache_key} if exists $cache->{$cache_key};

  my $header_value = $permsgstatus->get($header_name);
  my @emails = _extract_email_addresses($header_value);

  # No email found in this header => rule not hit.
  if (!@emails) {
    $cache->{$cache_key} = 0;
    return 0;
  }

  my $api_url = $conf->{ctj_email_check_api_url};
  my $timeout_seconds = $conf->{ctj_email_check_timeout_seconds};
  my $script_path = $conf->{ctj_email_check_script_path};
  my $python_bin = $conf->{ctj_email_check_script_python_bin};
  my $script_endpoint = $conf->{ctj_email_check_script_endpoint};

  # Hit if ANY extracted email address is invalid.
  for my $email (@emails) {
    my $local_check = _analyze_email_local($email);
    my $local_valid = $local_check->{valid};

    # If the address fails local syntax validation, we should always flag it,
    # regardless of whether the paid endpoint says otherwise.
    if (!$local_valid) {
      $cache->{$cache_key} = 1;
      return 1;
    }

    my $valid;

    if ($script_path && $script_path ne '') {
      my $script_valid = _analyze_email_via_script(
        $python_bin,
        $script_path,
        $script_endpoint,
        $email,
        $timeout_seconds,
      );
      if (defined $script_valid) {
        $valid = $script_valid;
      }
      elsif ($api_url && $api_url ne '') {
        my $api_valid = _analyze_email_via_api($api_url, $email, $timeout_seconds);
        $valid = defined($api_valid) ? $api_valid : 1;
      }
      else {
        $valid = 1;
      }
    }
    elsif ($api_url && $api_url ne '') {
      my $api_valid = _analyze_email_via_api($api_url, $email, $timeout_seconds);
      if (defined $api_valid) {
        $valid = $api_valid;
      }
      else {
        # API likely returned 402/503/timeout; fall back to local validation.
        $valid = 1;
      }
    }
    else {
      # Local validation already known to be valid.
      $valid = 1;
    }

    if (!$valid) {
      $cache->{$cache_key} = 1;
      return 1;
    }
  }

  $cache->{$cache_key} = 0;
  return 0;
}

1;

