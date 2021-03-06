require 'spec_helper'

shared_examples 'Invoice Item API' do

  context "creating a new invoice item" do
    it "creates a stripe invoice item" do
      invoice_item = Stripe::InvoiceItem.create({
        amount: 1099,
        customer: 1234,
        currency: 'USD',
        description: "invoice item desc"
      }, 'abcde')

      expect(invoice_item.id).to match(/^test_ii/)
      expect(invoice_item.amount).to eq(1099)
      expect(invoice_item.description).to eq('invoice item desc')
    end

    it "stores a created stripe invoice item in memory" do
      invoice_item = Stripe::InvoiceItem.create
      data = test_data_source(:invoice_items)
      expect(data[invoice_item.id]).to_not be_nil
      expect(data[invoice_item.id][:id]).to eq(invoice_item.id)
    end

    it "creates a invoice item with a price" do
      product = stripe_helper.create_product
      price = Stripe::Price.create(product: product.id, currency: "eur", unit_amount: 158)

      invoice_item = Stripe::InvoiceItem.create(id: "ii_1", price: price.id)

      expect(invoice_item.price).to eq(price)
      expect(invoice_item.amount).to eq(158)
    end

    it "associates the invoice item to the invoice" do
      customer = Stripe::Customer.create
      # create a first item, required for the invoice creation
      ii1 = Stripe::InvoiceItem.create(customer: customer)
      invoice = Stripe::Invoice.create(customer: customer)

      ii2 = Stripe::InvoiceItem.create(invoice: invoice, customer: customer)
      invoice.refresh

      expect(ii2.invoice).to eq(invoice.id)
      expect(invoice.lines.data.count).to eq(2)
      expect(invoice.lines.data[0].invoice_item).to eq(ii1.id)
      expect(invoice.lines.data[1].invoice_item).to eq(ii2.id)
    end
  end

  context "retrieving an invoice item" do
    it "retrieves a stripe invoice item" do
      original = Stripe::InvoiceItem.create
      invoice_item = Stripe::InvoiceItem.retrieve(original.id)
      expect(invoice_item.id).to eq(original.id)
    end

    it "returns the invoice item with associated price instance" do
      product = stripe_helper.create_product
      price = Stripe::Price.create(product: product.id, currency: "eur", unit_amount: 158)

      Stripe::InvoiceItem.create(id: "ii_1", price: price.id)

      invoice_item = Stripe::InvoiceItem.retrieve("ii_1")

      expect(invoice_item.price).to eq(price)
      expect(invoice_item.amount).to eq(158)
    end
  end

  context "retrieving a list of invoice items" do
    before do
      Stripe::InvoiceItem.create({ amount: 1075 })
      Stripe::InvoiceItem.create({ amount: 1540 })
    end

    it "retrieves all invoice items" do
      all = Stripe::InvoiceItem.list
      expect(all.count).to eq(2)
      expect(all.map &:amount).to include(1075, 1540)
    end
  end

  it "updates a stripe invoice_item" do
    original = Stripe::InvoiceItem.create(id: 'test_invoice_item_update')
    amount = original.amount

    original.description = 'new desc'
    original.save

    expect(original.amount).to eq(amount)
    expect(original.description).to eq('new desc')

    invoice_item = Stripe::InvoiceItem.retrieve("test_invoice_item_update")
    expect(invoice_item.amount).to eq(original.amount)
    expect(invoice_item.description).to eq('new desc')
  end

  it "updates a stripe invoice_item with a price" do
    product = stripe_helper.create_product
    price = Stripe::Price.create(product: product.id, currency: "eur", unit_amount: 158)

    original = Stripe::InvoiceItem.create(id: 'test_invoice_item_update')
    original.price = price
    original.save

    expect(original.price).to eq(original.price)
    expect(original.amount).to eq(158)

    invoice_item = Stripe::InvoiceItem.retrieve("test_invoice_item_update")
    expect(invoice_item.price).to eq(price)
    expect(invoice_item.amount).to eq(158)
  end

  it "updates an invoice_item with an invoice" do
    customer = Stripe::Customer.create
    invoice_item = Stripe::InvoiceItem.create(customer: customer)

    expect(invoice_item.invoice).to be_nil

    invoice = Stripe::Invoice.create(customer: customer)

    invoice_item.invoice = invoice
    invoice_item.save

    expect(invoice_item.invoice).to eq(invoice.id)
    expect(invoice.lines.data[0].invoice_item).to eq(invoice_item.id)
  end

  it "updates an invoice_item for invoice disassociation" do
    customer = Stripe::Customer.create
    invoice_item = Stripe::InvoiceItem.create(customer: customer)
    invoice = Stripe::Invoice.create(customer: customer)

    expect(invoice_item.refresh.invoice).to_not be_nil

    invoice_item.invoice = nil
    invoice_item.save

    expect(invoice_item.invoice).to be_nil
    expect(invoice.refresh.lines).to be_empty
  end

  it "deletes an invoice_item" do
    invoice_item = Stripe::InvoiceItem.create(id: 'test_invoice_item_sub')
    invoice_item = invoice_item.delete
    expect(invoice_item.deleted).to eq true
  end

  it "deleting an invoice_item remove it from invoice" do
    customer = Stripe::Customer.create
    invoice_item = Stripe::InvoiceItem.create(customer: customer)
    invoice = Stripe::Invoice.create(customer: customer)

    expect(invoice.lines.data[0].invoice_item).to eq(invoice_item.id)
    invoice_item.delete

    invoice.refresh
    expect(invoice.lines).to be_empty
  end
end
