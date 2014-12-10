# This file has been auto-generated only because it didn't exist.
# Feel free to modify it at will; it will not be overwritten automatically.

package SL::DB::AccTransaction;

use strict;

use SL::DB::MetaSetup::AccTransaction;
use SL::DB::Manager::AccTransaction;
use SL::DB::Invoice;
use SL::DB::PurchaseInvoice;
use SL::DB::GLTransaction;
use SL::Locale::String qw(t8);

__PACKAGE__->meta->initialize;

sub get_type {
  my $self = shift;

  my $transaction_obj;
  $transaction_obj = SL::DB::Manager::Invoice->find_by(id => $self->trans_id);
  if ( ref($transaction_obj) ) {
    return "ar";
  };
  unless ( ref($transaction_obj) ) {
    $transaction_obj = SL::DB::Manager::PurchaseInvoice->find_by(id => $self->trans_id);
    return "ap" if ref($transaction_obj);
  };
  unless ( ref($transaction_obj) ) {
    $transaction_obj = SL::DB::Manager::GLTransaction->find_by(id => $self->trans_id);
    return "gl" if ref($transaction_obj);
  };
  die "Can't find trans_id " . $self->trans_id . " in ar, ap or gl" unless ref($transaction_obj);

};

sub transaction_name {
  my $self = shift;

  my $transaction_obj;
  my $name = "trans_id: " . $self->trans_id;
  if ( $self->get_type eq 'ar' ) {
    $transaction_obj = SL::DB::Manager::Invoice->find_by(id => $self->trans_id);
    $name .= " (" . $transaction_obj->abbreviation . " " . t8("AR") . ") " . t8("Invoice Number") . ": " . $transaction_obj->invnumber;
  } elsif ( $self->get_type eq 'ap' ) {
    $transaction_obj = SL::DB::Manager::PurchaseInvoice->find_by(id => $self->trans_id);
    $name .= " (" . $transaction_obj->abbreviation . " " . t8("AP") . ") " . t8("Invoice Number") . ": " . $transaction_obj->invnumber;
  } elsif ( $self->get_type eq 'gl' ) { 
    $transaction_obj = SL::DB::Manager::GLTransaction->find_by(id => $self->trans_id);
    $name = "trans_id: " . $self->trans_id . " (" . $transaction_obj->abbreviation . ") " . $transaction_obj->reference . " - " . $transaction_obj->description if ref($transaction_obj);
  } else {
    die "can't determine type of acc_trans line with trans_id " . $self->trans_id;
  };

  $name .= "   " . t8("Date") . ": " . $self->transdate->to_kivitendo;

  return $name;

};

1;

__END__

=pod

=head1 NAME

SL::DB::AccTransaction: Rose model for acc_trans

=head1 FUNCTIONS

=over 4

=item C<get_type>

Returns the type of transaction the acc_trans entry belongs to: ar, ap or gl.

Console example:
 my $acc = SL::DB::Manager::AccTransaction->get_first();
 my $type = $acc->get_type;

=item C<transaction_name>

Generate a meaningful transaction name for an acc_trans line from the
corresponding ar/ap/gl object, a combination of trans_id,
invnumber/description, abbreviation. Can be used for better error output for
DATEV export.

=cut
