#!/usr/bin/perl

package API::Octopart;
use strict;

use JSON;
use LWP::UserAgent;
use Digest::MD5 qw(md5_hex);

use Data::Dumper;

=head1 NAME

API::Octopart - Simple inteface for querying part status across vendors at octopart.com.

=head1 SYNOPSIS

	my $o = API::Octopart->new(
		token => 'abcdefg-your-octopart-token-here',
		cache => "$ENV{HOME}/.octopart/cache",
		ua_debug => 1,
		);

	# Query part stock:
	my %opts = (
		currency => 'USD',
		max_moq => 100,
		min_qty => 10,
		max_price => 4,
		#mfg => 'Murata',
	);
	print Dumper $o->get_part_stock_detail('RC0805FR-0710KL', %opts);
	print Dumper $o->get_part_stock_detail('GQM1555C2DR90BB01D', %opts);

=head1 METHODS

=over 4

=item * $o = API::Octopart->new(%opts) - Returns new Octopart object.

Object Options (%opt):

Your Octopart API token:

		token => 'abcdefg-your-octopart-token-here',

You could do something like this to read the token from a file:

		token => (sub { my $t = `cat ~/.octopart/token`; chomp $t; return $t})->(),
	
An optional cache directory to minimize requests to Octopart:

		cache => "$ENV{HOME}/.octopart/cache", ua_debug => 1,

	
=cut 

sub new
{
	my ($class, %args) = @_;

	$args{api_queries} = 0;

	die "An Octopart API token is required." if (!$args{token});

	return bless(\%args, $class);
}


=item * $o->get_part_stock_detail($part, %opts) - Returns a stock detail structure

$part, %opts: same as has_stock().

Returns a structure like this:

        [
            {
                'mfg'     => 'Yageo',
                'sellers' => {
                    'Digi-Key' => {
                        'moq'        => 1,
                        'moq_price'  => '0.1',
                        'price_tier' => {
                            '1'    => '0.1',
                            '10'   => '0.042',
                            '100'  => '0.017',
                            '1000' => '0.00762',
                            '2500' => '0.00661',
                            '5000' => '0.00546'
                        },
                        'stock' => 4041192
                    },
                    ...
                },
                'specs' => {
                    'case_package'       => '0805',
                    'composition'        => 'Thick Film',
                    'contactplating'     => 'Tin',
                    'leadfree'           => 'Lead Free',
                    'length'             => '2mm',
                    'numberofpins'       => '2',
                    'radiationhardening' => 'No',
                    'reachsvhc'          => 'No SVHC',
                    'resistance' =>
                      "10k\x{ce}\x{a9}",    # <- That is an Ohm symbol
                    'rohs'              => 'Compliant',
                    'tolerance'         => '1%',
                    'voltagerating_dc_' => '150V',
                    'width'             => '1.25mm',
		    ...
                }
            },
            ...
        ]

=cut

sub get_part_stock_detail
{
	my ($self, $part, %opts) = @_;

	my $p = $self->query_part_detail($part);

	return $self->_parse_part_stock($p, %opts);
}


=item * $o->has_stock($part, %opts) - Returns the number of items in stock

$part: The model number of the part

%opts: Optional filters. No defaults are specified, it will return all unless limited.

	currency: The currency for which purchase is accepted (eg, USD)
	max_moq: The maximum "Minimum Order Quantity" you are willing to accept.
	min_qty: The minimum quantity that must be available
	max_price: The max price you are willing to pay
	mfg: The manufacturer name, in case multiple parts have the same model

=cut

sub has_stock
{
	my ($self, $part, %opts) = @_;

	my $parts = $self->get_part_stock_detail($part, %opts);

	my $stock = 0;
	foreach my $p (@$parts)
	{
		foreach my $s (values(%{ $p->{sellers} }))
		{
			$stock += $s->{stock}
		}
	}

	return $stock;
}

=item * $o->octo_query($q) - Returns new Octopart object.

Return the JSON response structure as a perl ARRAY/HASH given a query meeting Octopart's
API specification.

=cut

sub octo_query
{
	my ($self, $q) = @_;
	my $part = shift;


	my $content;

	my $h = md5_hex($q);
	my $hashfile = "$self->{cache}/$h.query";

	if ($self->{cache} && -e $hashfile)
	{
		system('mkdir', '-p', $self->{cache}) if (! -d $self->{cache});



		if (open(my $in, $hashfile))
		{
			local $/;
			$content = <$in>;
			close($in);
		}
	}
	else
	{
		my $ua = LWP::UserAgent->new( agent => 'mdf-perl/1.0',);

		$self->{api_queries}++;

		if ($self->{ua_debug})
		{
			$ua->add_handler(
			  "request_send",
			  sub {
			    my $msg = shift;              # HTTP::Message
			    $msg->dump( maxlength => 0 ); # dump all/everything
			    return;
			  }
			);

			$ua->add_handler(
			  "response_done",
			  sub {
			    my $msg = shift;                # HTTP::Message
			    $msg->dump( maxlength => 512 ); # dump max 512 bytes (default is 512)
			    return;
			  }
			);
		}

		my $req = HTTP::Request->new('POST' => 'https://octopart.com/api/v4/endpoint',
			 HTTP::Headers->new(
				'Host' => 'octopart.com',
				'Content-Type' => 'application/json',
				'Accept' => 'application/json',
				'Accept-Encoding' => 'gzip, deflate',
				'token' => $self->{token},
				'DNT' => 1,
				'Origin' => 'https://octopart.com',
				),
			encode_json( { query => $q }));

		my $response = $ua->request($req);

		if (!$response->is_success) {
			die $response->status_line;
		}

		$content = $response->decoded_content;

		if ($self->{cache})
		{
			open(my $out, ">", $hashfile) or die "$hashfile: $!";
			print $out $content;
			close($out);
		}
	}

	return from_json($content);
}


=item * $o->octo_query_count() - Return the number of API calls so far.
=cut

sub octo_query_count
{
	my $self = shift;
	return $self->{api_queries};
}

=item * $o->query_part_detail($part) - Returns new Octopart object.

Return the JSON response structure as a perl ARRAY/HASH given a part search term
shown as "$part".  This function calls $o->octo_query() with a query from Octopart's
"Basic Example" so you can easily lookup a specific part number.  The has_stock()
and get_part_stock_detail() methods use this query internally.

=cut

sub query_part_detail
{
	my ($self, $part) = @_;

	return $self->octo_query( qq(
		query {
		  search(q: "$part", limit: 3) {
		    results {
		      part {
			manufacturer {
			  name
			}
			mpn
			specs {
			  units
			  value
			  display_value
			  attribute {
			    id
			    name
			    shortname
			    group
			  }
			}
			# Brokers are non-authorized dealers. See: https://octopart.com/authorized
			sellers(include_brokers: false) {
			  company {
			    name
			  }
			  offers {
			    click_url
			    inventory_level
			    prices {
			      price
			      currency
			      quantity
			    }
			  }
			}
		      }
		    }
		  }
		}
	));
}

our %_valid_filter_opts = ( map { $_ => 1 } (qw/currency max_moq min_qty max_price mfg seller/) );
sub _parse_part_stock
{
	my ($self, $resp, %opts) = @_;

	foreach my $o (keys %opts)
	{
		die "invalid filter option: '$o'" if (!$_valid_filter_opts{$o});
	}

	my @results;
	foreach my $r (@{ $resp->{data}{search}{results} })
	{
		$r = $r->{part};
		next if (!scalar(@{ $r->{specs} // [] }));

		my %part = (
			mfg => $r->{manufacturer}{name},
			specs => {
				# Try to map first by shortname, then by unit, then by value if
				# the former are undefined:
				map { 
					defined($_->{attribute}{shortname}) 
						? ($_->{attribute}{shortname} => $_->{value} . "$_->{units}")
						: (
							$_->{units} 
								? ($_->{units} => $_->{value})
								: ($_->{value} => 'true')
						)
				} @{ $r->{specs} }
			},
		);

		# Seller stock and MOQ pricing:
		my %ss;
		foreach my $s (@{ $r->{sellers} })
		{
			foreach my $o (@{ $s->{offers} })
			{
				$ss{$s->{company}{name}}{stock} = $o->{inventory_level};
				foreach my $p (@{ $o->{prices} })
				{
					next if (defined($opts{currency}) && $p->{currency} ne $opts{currency});

					my $moq = $p->{quantity};
					my $price = $p->{price};

					$ss{$s->{company}{name}}{price_tier}{$p->{quantity}} = $price;

					# Find the minimum order quantity and the MOQ price:
					if (!defined($ss{$s->{company}{name}}{moq}) ||
						$ss{$s->{company}{name}}{moq} > $moq)
					{
						$ss{$s->{company}{name}}{moq} = $moq;
						$ss{$s->{company}{name}}{moq_price} = $price;
					}
				}
			}
		}

		$part{sellers} = \%ss;

		push @results, \%part;
	}

	# Delete sellers that do not meet the constraints and
	# add matching results to @ret:
	my @ret;
	foreach my $r (@results)
	{
		next if (defined($opts{mfg}) && $r->{mfg} !~ /$opts{mfg}/i);

		foreach my $s (keys %{ $r->{sellers} })
		{
			if (!defined($r->{sellers}{$s}{price_tier})
				|| (defined($opts{min_qty}) && $r->{sellers}{$s}{stock} < $opts{min_qty})
				|| (defined($opts{max_price}) && $r->{sellers}{$s}{moq_price} > $opts{max_price})
				|| (defined($opts{max_moq}) && $r->{sellers}{$s}{moq} > $opts{max_moq}
				|| defined($opts{seller}) && $s !~ /$opts{seller}/i)
			   )
			{
				delete $r->{sellers}{$s};
			}
		}

		push @ret, $r;
	}

	return \@ret;
}

=back

=head1 SEE ALSO

L<https://octopart.com/>, L<https://octopart.com/api>

=head1 ATTRIBUTION

Octopart is a registered trademark and brand of Octopart, Inc.  All tradmarks,
product names, logos, and brands are property of their respective owners and no
grant or license is provided thereof.

The copyright below applies to this software module; the copyright holder is
unaffiliated with Octopart, Inc.

=head1 AUTHOR

Originally written at eWheeler, Inc. dba Linux Global by Eric Wheeler
to facilitate optimization of RF matching components, but only for
components that are available for purchase at electronic component
vendors (of course!) L<https://youtu.be/xbdBjR4szjE>

=head1 COPYRIGHT

Copyright (C) 2022 eWheeler, Inc. dba Linux Global
L<https://www.linuxglobal.com/>

This module is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version.

This module is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with
this module. If not, see <http://www.gnu.org/licenses/>.

=cut

1;
