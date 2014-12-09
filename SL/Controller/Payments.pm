package SL::Controller::Payments;

use strict;

use parent qw(SL::Controller::Base);
use SL::DB::Invoice;
use SL::DB::PurchaseInvoice;
use SL::DB::BankAccount;
use SL::Controller::Helper::GetModels;
use SL::Controller::Helper::ParseFilter;
use SL::Locale::String qw(t8);
use SL::DB::Helper::Payment qw(validate_payment_type);
use SL::Helper::Flash;
use SL::ClientJS;

use SL::Helper::DateTime;
use SL::Controller::Helper::ReportGenerator;

__PACKAGE__->run_before('check_auth');

use Rose::Object::MakeMethods::Generic (
  'scalar --get_set_init' => [ qw(ap_models ar_models) ],
);

sub action_list_open_invoices {

  my ($self, %params) = @_;

  die "illegal vc type\n" unless $::form->{vc} =~ m/^(vendor|customer)$/;

  my $title = $::form->{vc} eq 'vendor' ? $::locale->text('Open purchase invoices')
                                        : $::locale->text('Open sales invoices');

  $::request->layout->use_javascript('client_js.js');

  my $bank_accounts = SL::DB::Manager::BankAccount->get_all();

  my $today = DateTime->now->to_kivitendo;

  # fill out fields via jquery commands in template with the following
  # parameters if these are passed via get
  # e.g. controller.pl?action=Payments/list_open_invoices&vc=vendor&invnumber=192
  my %initfilter = ( name          => $::form->{name},
                     customernumber=> $::form->{customernumber},
                     vendornumber  => $::form->{vendornumber},
                     invnumber     => $::form->{invnumber},
                   );

  # The actual loading of invoices happens in action_invoicelist_dynamic_table,
  # which is processed inside this template and automatically called upon
  # loading. This causes all open invoices and credit notes to be displayed,
  # there is no paginate mechanism
  $self->render('payments/invoices', { layout => 1, process => 1 },
                                     title         => $title,
                                     BANK_ACCOUNTS => $bank_accounts,
                                     DATE          => $today,
                                     vc            => $::form->{vc},
                                     initfilter    => \%initfilter
                                   );
}


sub action_invoicelist_dynamic_table {
  my ($self) = @_;

  my $vc = $::form->{vc};

  my $invoices = $vc eq 'vendor' ? $self->ap_models->get : $self->ar_models->get;

  # get drop-down data for payment types and the suggested amount for each invoice
  foreach my $invoice ( @{$invoices} ) {
    $invoice->get_payment_suggestions;
  };

  $self->render('payments/_invoice_list', { layout  => 0 , process => 1 }, INVOICES => $invoices, vc => $vc);
}

sub init_ap_models {
  my ($self) = @_;

  SL::Controller::Helper::GetModels->new(
    controller => $self,
    model      => 'PurchaseInvoice',
    query      =>  [amount => { ne => \'paid' }],
    with_objects => [ qw(vendor) ],
    sorted     => {
      _default   => {
        by  => 'transdate',
        dir => 1,
      },
      transdate => t8('Transdate'),
      invnumber => t8('Invoice Number'),
      vendor    => t8('Vendor Name'),
    },
  );
}

sub init_ar_models {
  my ($self) = @_;

  SL::Controller::Helper::GetModels->new(
    controller => $self,
    model      => 'Invoice',
    query      =>  [amount => { ne => \'paid' }], # use ne instead of gt, so open credit notes are also shown
    with_objects => [ qw(customer) ],
    sorted     => {
      _default   => {
        by  => 'transdate',
        dir => 1,
      },
      transdate => t8('Transdate'),
      invnumber => t8('Invoice Number'),
      customer  => t8('Customer Name'),
    },
  );
}

sub action_pay_invoice {

 my ($self) = @_;

 my $js = SL::ClientJS->new;

 my $invoice = $::form->{vc} eq 'customer' ? SL::DB::Manager::Invoice->find_by(id => $::form->{arap_id})
                                           : SL::DB::Manager::PurchaseInvoice->find_by(id => $::form->{arap_id});

 unless ( ref $invoice ) {
   $js->flash('error', t8('Invoice can\'t be found'));
   return $self->render($js);
 };

 validate_payment_type($::form->{payment_type});

 my $pay_amount = $::form->parse_amount(\%::myconfig, $::form->{amount});
 unless ( $pay_amount != 0 ) {
   $js->focus('#pay_amount_' . $::form->{loop});
   $js->flash('error', t8('Illegal amount'));
   return $self->render($js);
 };

 my $bank = SL::DB::Manager::BankAccount->find_by(chart_id => $::form->{bank_id});

 unless ( ref $bank ) {
   $js->flash('error', t8('Bank Account can\'t be found'));
   return $self->render($js);
 };

 my %params = (chart_id     => $bank->chart_id,
               trans_id     => $invoice->id,
               amount       => $pay_amount,
               source       => $::form->{source},
               payment_type => $::form->{payment_type},
               transdate    => $::form->{global_payment_date});

 # pay invoice
 my $return = $invoice->pay_invoice(%params);

 if ( $return ) {
   if ( $::form->{payment_type} eq 'with_skonto_pt' ) {
     $js->flash('info', t8('Invoice #1: paid #2 to bank #3, rest for skonto.', $invoice->invnumber, $::form->{skonto} ? $::form->{skonto_paid} : $::form->{amount}, $bank->name ));
   } elsif (  $::form->{payment_type} eq 'difference_as_skonto' ) {
     $js->flash('info', t8('Invoice #1: paid #2 to skonto.', $invoice->invnumber, $::form->{amount}));
   } else {   # without_skonto
     $js->flash('info', t8('Invoice #1: paid #2 to bank #3.', $invoice->invnumber, $::form->{amount}, $bank->name ));
   };

   # dynamically change information in table: hide line if fully paid, otherwise update numbers and dropdown
   if ( $::form->round_amount( $invoice->open_amount, 2) == 0 ) {
     $js->hide('#tr_' . $::form->{loop});
   } else {
     # invoice is still partially open, so dynamically change the data in the table:
     my $new_open_amount =  $::form->format_amount( \%::myconfig, $invoice->open_amount, 2);
     $js->val( '#pay_amount_' . $::form->{loop}, $new_open_amount);
     $js->val( '#invoice_open_amount_' . $::form->{loop}, $new_open_amount); # hidden
     my $new_open_formatted_amount_with_percent = $new_open_amount . "(" . $::form->format_amount( \%::myconfig, ($invoice->amount - $invoice->paid)*100/$invoice->amount, 2) . "%)";
     $js->html('#open_'       . $::form->{loop}, $new_open_formatted_amount_with_percent);
     $js->html('#paid_'       . $::form->{loop}, $invoice->paid_as_number);
     # $js->addClass('#open_'       . $::form->{loop}, 'skonto');  # works!

     # after partially paying an invoice , only without_skonto and difference_as_skonto are allowed:
     # difference_as_skonto should only be available for small open amounts
     my $select_options = '<option value="without_skonto" select="selected">' . t8('without skonto') . '</option>';
     $select_options .=  '<option value="difference_as_skonto">' . t8('difference as skonto') if $invoice->paid > $invoice->open_amount;
     $select_options .= '</option>';
     $js->html('#payment_type_' . $::form->{loop}, $select_options);

   };
   return $self->render($js);
 } else {
   $js->flash('info', t8('something went wrong'));
   return $self->render($js);
 };

 $self->render($js);

};

sub check_auth {
  $::auth->assert('general_ledger');
}

1;

__END__

=encoding utf-8

=head1 TODO AND CAVEATS

=over 4

=item *

Currently only configured bank accounts may be used for payments (like SEPA),
not AR_paid or AP_paid accounts.

=item *

Credit notes are displayed with minus values

=cut
