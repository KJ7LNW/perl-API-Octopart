#!/usr/bin/perl

package API::Octopart;
use strict;

use JSON;
use LWP::UserAgent;
use Digest::MD5 qw(md5_hex);

use Data::Dumper;

=head1 NAME

API::Octopart - Simple inteface for querying part status across vendors.

=head1 SYNOPSIS

	my $o = Octopart->new(
		token => (sub { my $t = `cat ~/.octopart/token`; chomp $t; return $t})->(),
		cache => "$ENV{HOME}/.octopart/cache",
		ua_debug => 1,
		);
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

=item * has_stock($part, %opts) - Returns true if in stock.

=over 4

$part: The model number of the part

%opts: Optional filters:

	currency: The currency for which purchase is accepted (eg, USD)
	max_moq: The maximum "Minimum Order Quantity" you are willing to accept.
	min_qty: The minimum quantity that must be available
	max_price: The max price you are willing to pay
	mfg: The manufacturer name, in case multiple parts have the same model

=back 4

=item * get_part_stock_detail($part, %opts) - Returns a stock detail structure

=over 4
$part, %opts: same as above.

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
                    'width'             => '1.25mm'
                }
            },
            ...
        ]

=back 4

=cut

sub get_part_stock_detail
{
	my ($self, $part, %opts) = @_;
	
	my $p = $self->query_part_detail($part);

	return $self->_parse_part_stock($p, %opts);
}

sub has_stock
{
	my ($self, $part, %opts) = @_;

	my $parts = $self->get_part_stock_detail($part, %opts);

	foreach my $p (@$parts)
	{
		if (scalar(keys(%{ $p->{sellers} })))
		{
			return 1;
		}
	}

	return 0;
}

sub _parse_part_stock
{
	my ($self, $resp, %opts) = @_;

	my @results;
	foreach my $r (@{ $resp->{data}{search}{results} })
	{
		$r = $r->{part};
		next if (!scalar(@{ $r->{specs} // [] }));

		my %part = (
			mfg => $r->{manufacturer}{name},
			specs => {
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
		next if (defined($opts{mfg}) && $r->{mfg} ne $opts{mfg});

		foreach my $s (keys %{ $r->{sellers} })
		{
			if (!defined($r->{sellers}{$s}{price_tier})
				|| (defined($opts{min_qty}) && $r->{sellers}{$s}{stock} < $opts{min_qty})
				|| (defined($opts{max_price}) && $r->{sellers}{$s}{moq_price} > $opts{max_price})
				|| (defined($opts{max_moq}) && $r->{sellers}{$s}{moq} > $opts{max_moq})
			   )
			{
				delete $r->{sellers}{$s};
			}
		}

		push @ret, $r;
	}

	return \@ret;
}

sub new
{
	my ($class, %args) = @_;

	return bless(\%args, $class);
}

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
			sellers(include_brokers: true) {
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

1;
