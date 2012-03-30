#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Pod::Usage;
use Getopt::Long;

use Carp;
use Config::Pit;
use WWW::Mechanize;
use IO::Uncompress::Gunzip 'gunzip';
use Text::CSV;
use IO::Scalar;
use YAML ();
use JSON;

GetOptions(
    \my %option,
    qw/help ls yaml json id=s/,
);
pod2usage(0) if $option{help};

my $conf = pit_get 'itunesconnect.apple.com', require => {
    email    => 'your itunes connect email',
    password => 'your itunes connect password',
};

my $mech = WWW::Mechanize->new( stack_depth => 1 );
$mech->agent_alias('Mac Safari');
my $viewstate = '';

my $assert_html = sub {
    my ($m, $pattern) = @_;
    $m->content =~ $pattern
        or do {
            warn $m->content;
            croak sprintf 'assertion failed, %s', $m->uri;
        };
};

sub main {
    my $date = $ARGV[0];

    if (!$option{ls} and !$date) {
        pod2usage('date required');
    }

    login();
    my @dates = open_sales_page();

    if ($option{ls}) {
        for my $d (@dates) {
            print $d, "\n";
        }
        exit;
    }

    grep { $date eq $_ } @dates
        or die "Date: $date is not available at this time\n";

    select_sales_tab($date);
    my $report = download_report($date);

    if ($option{yaml} || $option{json}) {
        my $io = IO::Scalar->new(\$report);

        my $csv = Text::CSV->new({
            binary   => 1,
            sep_char => "\x9", # tab
        });

        my $header = $csv->getline($io);
        my @rows;

    ROW:
        while (my $row = $csv->getline($io)) {
            my %r;

            for (my $i = 0; $i < @$header; $i++) {
                if ($option{id} and $header->[$i] eq 'Apple Identifier') {
                    next ROW unless $row->[$i] eq $option{id};
                }

                $r{ $header->[$i] } = $row->[$i];
            }

            push @rows, \%r;
        }
        $csv->eof;

        if ($option{yaml}) {
            print YAML::Dump(\@rows);
        }
        else {
            print encode_json(\@rows);
        }
    }
    else {
        if ($option{id}) {
            die "--id options only support combination usage with --json or --yaml\n";
        }

        print $report;
    }
}

sub login {
    $mech->get('https://itunesconnect.apple.com/');
    $mech->success or die 'Cannot access itunesconnect.apple.com';

    $mech->submit_form(
        with_fields => {
            theAccountName => $conf->{email},
            theAccountPW   => $conf->{password},
        },
    );
    $mech->success or die 'Cannot login';

    $mech->$assert_html(qr/Sales and Trends/);
}

sub open_sales_page {
    $mech->follow_link( text => 'Sales and Trends' );
    $mech->success or die 'Cannot access Sales and Trends';

    my $form = $mech->form_id('defaultVendorPage')
        or die 'Cannot find navigation form';

    $mech->$assert_html(qr/j_id_jsp_111414985_2['"]/);

    my @f = $form->form;

    $mech->post($mech->uri, [
        @f,
        AJAXREQUEST                              => 'j_id_jsp_111414985_2',
        'defaultVendorPage:j_id_jsp_111414985_2' => 'defaultVendorPage:j_id_jsp_111414985_2',
    ]);
    $mech->success or die 'failed to ajax';

    my $redirect = $mech->uri->clone;
    $redirect->path($mech->res->header('Location') || die 'Cannot find redirect uri');

    $mech->get($redirect);
    $mech->success or die 'Cannot access sales page';

    my ($form_id) = $mech->content =~ /theForm:(j_id_jsp_\d+)/;

    $mech->$assert_html(qr/${form_id}_11/);
    $mech->$assert_html(qr/${form_id}_12/);
    $mech->$assert_html(qr/${form_id}_13/);

    my ($datechunk) = $mech->content =~ /<select id="theForm:datePickerSourceSelectElement"(.*?)<\/select>/s;
    my @dates = $datechunk =~ /value="(.*?)"/g
        or die 'cannot find date liste';

    $form = $mech->form_id('theForm');
    my %f = $form->form;

    $viewstate = $f{'javax.faces.ViewState'};

    $mech->post('https://reportingitc.apple.com/subdashboard.faces', [
        AJAXREQUEST                             => "theForm:${form_id}_2",
        'theForm'                               => 'theForm',
        'theForm:hideval1'                      => '',
        'theForm:xyz'                           => 'notnormal',
        'theForm:prodtypesel'                   => 'Music',
        'theForm:subprodsel'                    => 'Songs',
        'theForm:subprodlabel'                  => 'songLabel',
        'theForm:selperiodId'                   => 'daily',
        'theForm:vendorLogin'                   => '',
        'theForm:datePickerSourceSelectElement' => $dates[0],
        'javax.faces.ViewState'                 => $f{'javax.faces.ViewState'},
        "theForm:${form_id}_11"                 => "theForm:${form_id}_11",
    ]);
    $mech->success or die 'failed to ajax 1';

    $mech->post('https://reportingitc.apple.com/subdashboard.faces', [
        AJAXREQUEST                             => "theForm:${form_id}_2",
        'theForm'                               => 'theForm',
        'theForm:hideval1'                      => '',
        'theForm:xyz'                           => 'notnormal',
        'theForm:prodtypesel'                   => 'Music',
        'theForm:subprodsel'                    => 'Songs',
        'theForm:subprodlabel'                  => 'songLabel',
        'theForm:selperiodId'                   => 'daily',
        'theForm:vendorLogin'                   => '',
        'theForm:datePickerSourceSelectElement' => $dates[0],
        'javax.faces.ViewState'                 => $f{'javax.faces.ViewState'},
        "theForm:${form_id}_12"                 => "theForm:${form_id}_12",
    ]);
    $mech->success or die 'failed to ajax 2';

    $mech->post('https://reportingitc.apple.com/jsp/json_holder.faces', [
        dtValue  => $dates[0],
        dateType => 'daily',
    ]);
    $mech->success or die 'failed to json_holder';

    $mech->post('https://reportingitc.apple.com/jsp/vendortype.jsp');
    $mech->success or die 'failed to vendortype';

    $mech->post('https://reportingitc.apple.com/subdashboard.faces', [
        AJAXREQUEST                             => "theForm:${form_id}_2",
        theForm                                 => 'theForm',
        'theForm:hideval1'                      => '',
        'theForm:xyz'                           => 'notnormal',
        'theForm:prodtypesel'                   => 'iOS',
        'theForm:subprodsel'                    => 'Free Apps',
        'theForm:subprodlabel'                  => 'freeAppLabel',
        'theForm:selperiodId'                   => 'daily',
        'theForm:vendorLogin'                   => '',
        'theForm:datePickerSourceSelectElement' => $dates[0],
        'javax.faces.ViewState'                 => $f{'javax.faces.ViewState'},
        'param1'                                => 'Free Apps',
        "theForm:${form_id}_13"                 => "theForm:${form_id}_13",
    ]);
    $mech->success or die 'failed to ajax3';

    my ($state) = $mech->content =~ /value="(j_id.*?)"/
        or die 'cannot update viewstate';
    $viewstate = $state;

    $mech->post('https://reportingitc.apple.com/jsp/providerselection.faces');
    $mech->success or die;

    @dates;
}

sub select_sales_tab {
    my $date = shift;

    $mech->post('https://reportingitc.apple.com/subdashboard.faces', [
        theForm                                 => 'theForm',
        'theForm:hideval1'                      => '',
        'theForm:xyz'                           => 'notnormal',
        'theForm:prodtypesel'                   => 'iOS',
        'theForm:subprodsel'                    => 'Free Apps',
        'theForm:subprodlabel'                  => 'freeAppLabel',
        'theForm:selperiodId'                   => 'daily',
        'theForm:vendorLogin'                   => '',
        'theForm:datePickerSourceSelectElement' => $date,
        'javax.faces.ViewState'                 => $viewstate,
        'theForm:saletestid'                    => 'theForm:saletestid',
    ]);
    $mech->success or die 'failed to switch sales tab';

    my ($form_id) = $mech->content =~ /theForm:(j_id_jsp_\d+)/;
    my %f = $mech->form_id('theForm')->form;

    $mech->$assert_html(qr/${form_id}_7/);

    $mech->post('https://reportingitc.apple.com/jsp/providerselectionsales.faces');
    $mech->success or die 'failed to get providerselectionsales';

    $mech->post('https://reportingitc.apple.com/sales.faces', [
        AJAXREQUEST                                  => "theForm:${form_id}_2",
        theForm                                      => 'theForm',
        'theForm:vendorLogin'                        => '',
        'theForm:xyz'                                => 'notnormal',
        'theForm:vendorType'                         => 'Y',
        'theForm:optInVar'                           => 'A',
        'theForm:dateType'                           => 'D',
        'theForm:optInVarRender'                     => 'false',
        'theForm:wklyBool'                           => 'false',
        'theForm:datePickerSourceSelectElementSales' => $date,
        'javax.faces.ViewState'                      => $f{'javax.faces.ViewState'},
        "theForm:${form_id}_7"                       => "theForm:${form_id}_7",
    ]);
    $mech->success or die 'failed to get sales face';

    my ($state) = $mech->content =~ /value="(j_id.*?)"/
        or die 'cannot update viewstate';
    $viewstate = $state;
}

sub download_report {
    my $date = shift;

    $mech->post('https://reportingitc.apple.com/sales.faces', [
        theForm                                      => 'theForm',
        'theForm:vendorLogin'                        => '',
        'theForm:xyz'                                => 'notnormal',
        'theForm:vendorType'                         => 'Y',
        'theForm:optInVar'                           => 'A',
        'theForm:dateType'                           => 'D',
        'theForm:optInVarRender'                     => 'false',
        'theForm:wklyBool'                           => 'false',
        'theForm:datePickerSourceSelectElementSales' => $date,
        'javax.faces.ViewState'                      => $viewstate,
        'theForm:downloadLabel2'                     => 'theForm:downloadLabel2',
    ]);
    $mech->success or die 'failed to download sale';

    ($mech->res->header('Filename') || '') =~ /\.txt\.gz$/
        or die 'Invalid download response';

    my $content = $mech->content;
    gunzip \$content => \my $decoded_content
        or die 'gunzip failed';

    utf8::decode($decoded_content);
    $decoded_content;
}

main();

__END__

=head1 NAME

itunes-connect.pl - itunes connect daily report downloader

=head1 SYNOPSIS

    itunes-connect.pl [options] <date>
    
    Options:
        -h --help    show this help
        -l --ls      show available date list
        -y --yaml    dump report as yaml format
        -j --json    dump report as json format
        -i --id      filter report by application id (only usable with --yaml or --json)

=head1 AUTHOR

Daisuke Murase <murase@kayac.com>

=cut
